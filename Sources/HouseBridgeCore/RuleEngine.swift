import Foundation

/// Performs rule actions. Implemented by the Hue client; tests and `--dry-run` use stand-ins.
public protocol ActionExecutor: Sendable {
    func execute(_ action: Action) async throws
}

/// Turns raw press/release timing from a Pico into tap, double_tap, hold and hold_release.
actor GestureDetector {
    private struct State {
        var generation = 0
        var isDown = false
        var held = false
        var secondPress = false
        var waitingForSecond = false
    }

    private var states: [String: State] = [:]
    private let holdMs: Int
    private let doubleTapMs: Int
    private let emit: @Sendable (TriggerEvent) -> Void

    init(holdMs: Int, doubleTapMs: Int, emit: @escaping @Sendable (TriggerEvent) -> Void) {
        self.holdMs = holdMs
        self.doubleTapMs = doubleTapMs
        self.emit = emit
    }

    func press(_ event: TriggerEvent) {
        var s = states[event.key] ?? State()
        s.generation += 1
        s.isDown = true
        s.held = false
        if s.waitingForSecond { s.secondPress = true }
        states[event.key] = s
        let gen = s.generation
        let ms = holdMs
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            await self?.holdElapsed(event, generation: gen)
        }
    }

    func release(_ event: TriggerEvent, wantsDoubleTap: Bool) {
        var s = states[event.key] ?? State()
        guard s.isDown else { return }
        s.generation += 1
        s.isDown = false
        if s.held {
            s.held = false
            s.secondPress = false
            s.waitingForSecond = false
            states[event.key] = s
            emit(event.with(kind: "hold_release"))
            return
        }
        if s.secondPress {
            s.secondPress = false
            s.waitingForSecond = false
            states[event.key] = s
            emit(event.with(kind: "double_tap"))
            return
        }
        if wantsDoubleTap {
            s.waitingForSecond = true
            states[event.key] = s
            let gen = s.generation
            let ms = doubleTapMs
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(ms))
                await self?.doubleTapWindowElapsed(event, generation: gen)
            }
        } else {
            states[event.key] = s
            emit(event.with(kind: "tap"))
        }
    }

    private func holdElapsed(_ event: TriggerEvent, generation: Int) {
        guard var s = states[event.key], s.generation == generation, s.isDown else { return }
        s.held = true
        s.secondPress = false
        s.waitingForSecond = false
        states[event.key] = s
        emit(event.with(kind: "hold"))
    }

    private func doubleTapWindowElapsed(_ event: TriggerEvent, generation: Int) {
        guard var s = states[event.key], s.generation == generation, s.waitingForSecond else { return }
        s.waitingForSecond = false
        states[event.key] = s
        emit(event.with(kind: "tap"))
    }
}

/// Receives events, applies rules, runs actions. One instance per loaded config.
public actor RuleEngine {
    private let config: Config
    private let executor: ActionExecutor
    private let log: @Sendable (LogEntry) -> Void
    private let onEvent: @Sendable (TriggerEvent) -> Void
    private let continuation: AsyncStream<TriggerEvent>.Continuation
    private let stream: AsyncStream<TriggerEvent>
    private var detector: GestureDetector?
    private var lastFired: [String: Date] = [:]
    private var repeaters: [String: Task<Void, Never>] = [:]
    private var clearTasks: [String: Task<Void, Never>] = [:]
    private var runner: Task<Void, Never>?
    private var simulators: [Task<Void, Never>] = []
    private var holidayTask: Task<Void, Never>?
    private struct AlarmState {
        var active = false
        /// Detections that have started and not yet ended (a person still in view).
        var present = Set<String>()
        var last = Date.distantPast
        var timer: Task<Void, Never>?
        /// Alarm actions run one after another, so an end can't overtake a start that came just before it.
        var chain: Task<Void, Never>?
    }
    private var alarmStates: [String: AlarmState] = [:]
    /// When each presence hold ends (only entries still in the future matter).
    private var holdUntil: [String: Date] = [:]
    private var holdTimers: [String: Task<Void, Never>] = [:]
    /// Pending `off_after_seconds` timers for Hue lights, by target. A later action on the same target replaces or cancels it.
    /// `switchName` is the Home.app switch to flip off when the timer ends or is cancelled; `off` is the command that ends it.
    private var lightOffTimers: [String: (targets: PauseTargets, task: Task<Void, Never>, switchName: String?, off: Action)] = [:]
    private let onSwitch: @Sendable (String, Bool) -> Void
    private let holdStore: HoldStore?
    private let cancelLutronTimers: @Sendable ([String]) -> Void
    private let cancelPlugTimers: @Sendable ([String]) -> Void
    private let now: @Sendable () -> Date
    private let catchUpOnStart: TimeInterval?
    private let retryDelays: [TimeInterval]
    private var retryTask: Task<Void, Never>?
    private var retryKeys = Set<String>()

    /// How long after a scheduled action fails (device unreachable) it is tried again; then it is given up.
    public static let defaultRetryDelays: [TimeInterval] = [60, 300, 900]

    public init(config: Config, executor: ActionExecutor,
                onEvent: @escaping @Sendable (TriggerEvent) -> Void = { _ in },
                holdStore: HoldStore? = nil,
                onSwitch: @escaping @Sendable (String, Bool) -> Void = { _, _ in },
                cancelLutronTimers: @escaping @Sendable ([String]) -> Void = { _ in },
                cancelPlugTimers: @escaping @Sendable ([String]) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() },
                catchUpOnStart: TimeInterval? = nil,
                retryDelays: [TimeInterval] = RuleEngine.defaultRetryDelays,
                log: @escaping @Sendable (LogEntry) -> Void) {
        self.catchUpOnStart = catchUpOnStart
        self.retryDelays = retryDelays
        self.config = config
        self.executor = executor
        self.log = log
        self.onEvent = onEvent
        self.holdStore = holdStore
        self.onSwitch = onSwitch
        self.cancelLutronTimers = cancelLutronTimers
        self.cancelPlugTimers = cancelPlugTimers
        self.now = now
        var cont: AsyncStream<TriggerEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    /// Thread-safe; may be called from any source adapter.
    public nonisolated func submit(_ event: TriggerEvent) {
        continuation.yield(event)
    }

    public func start() {
        guard runner == nil else { return }
        restoreHolds()
        if let delay = catchUpOnStart {
            // Gives Hue/Kasa a moment to connect; a failure is retried anyway.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                await self?.catchUp(reason: "startup")
            }
        }
        if config.holidays.contains(where: \.enabled) { holidayTask = Task { [weak self] in await self?.runHolidays() } }
        for sim in config.simulations where sim.enabled {
            simulators.append(Task { [weak self] in await self?.simulate(sim) })
        }
        let cont = continuation
        detector = GestureDetector(holdMs: config.timing.holdMs, doubleTapMs: config.timing.doubleTapMs) { cont.yield($0) }
        runner = Task { [weak self] in
            guard let stream = self?.stream else { return }
            for await event in stream {
                await self?.handle(event)
            }
        }
    }

    public func stop() {
        continuation.finish()
        runner?.cancel()
        runner = nil
        retryTask?.cancel()
        retryTask = nil
        retryKeys = []
        holdTimers.values.forEach { $0.cancel() }
        holdTimers = [:]
        simulators.forEach { $0.cancel() }
        simulators = []
        holidayTask?.cancel()
        holidayTask = nil
        // A reload or quit must not leave the sound playing and the lights on with nothing left to end them.
        for alarm in config.alarms where alarmStates[alarm.name]?.active == true {
            alarmStates[alarm.name]?.timer?.cancel()
            alarmStates[alarm.name]?.active = false
            queue(alarm.endSteps, for: alarm)
        }
        lightOffTimers.values.forEach { $0.task.cancel() }
        lightOffTimers = [:]
        repeaters.values.forEach { $0.cancel() }
        clearTasks.values.forEach { $0.cancel() }
        repeaters = [:]
        clearTasks = [:]
    }

    /// Visible for tests: processes one event synchronously with respect to the engine.
    func handle(_ event: TriggerEvent) async {
        onEvent(event)

        if event.source == .pico {
            if event.kind == "press" { await detector?.press(event) }
            if event.kind == "release" {
                await detector?.release(event, wantsDoubleTap: wantsDoubleTap(event))
            }
        }
        if event.source == .unifi { scheduleClear(for: event) }
        if event.kind == "release" || event.kind == "hold_release" {
            repeaters.removeValue(forKey: event.key)?.cancel()
        }

        // Holds first, so a sensor that starts a hold also pauses the rules it triggers.
        for hold in config.presence where hold.triggers.contains(where: { $0.matches(event) }) {
            extend(hold)
        }
        for alarm in config.alarms where alarm.enabled && alarm.matches(event) { alarmEvent(alarm, event) }
        for rule in config.rules where rule.enabled && rule.trigger.matches(event) {
            fire(rule, for: event)
        }
    }

    // MARK: Alarms

    /// A person detection starts the alarm (unless someone is home) or, once it is running, keeps it going. It ends
    /// `keepSeconds` after the last notification, or `maxSeconds` after it while a detection never reported its end.
    /// A hold that begins *during* an alarm does not stop it: a stranger at the door is what starts those holds.
    private func alarmEvent(_ alarm: Alarm, _ event: TriggerEvent) {
        var state = alarmStates[alarm.name] ?? AlarmState()
        if !state.active {
            guard event.kind == "start" else { return }
            if anyHoldActive {
                log(LogEntry(category: "alarm", message: "‘\(alarm.name)’ not started: someone is home (\(event.summary))"))
                return
            }
            state.active = true
            state.present = []
            alarmStates[alarm.name] = state
            log(LogEntry(category: "alarm", message: "‘\(alarm.name)’ STARTED by \(event.summary)"))
            queue(alarm.startSteps, for: alarm)
            state = alarmStates[alarm.name] ?? state
        }
        if event.kind == "start" { state.present.insert(event.key) } else { state.present.remove(event.key) }
        state.last = now()
        state.timer?.cancel()
        let name = alarm.name
        state.timer = Task { [weak self] in
            // Re-check after waking: Mac sleep or a later notification moves the deadline.
            while let remaining = await self?.alarmRemaining(name), remaining > 0 {
                try? await Task.sleep(for: .seconds(min(remaining, 60) + 0.05))
                if Task.isCancelled { return }
            }
            await self?.endAlarm(name)
        }
        alarmStates[alarm.name] = state
    }

    private func alarmRemaining(_ name: String) -> TimeInterval? {
        guard let alarm = config.alarms.first(where: { $0.name == name }), let state = alarmStates[name], state.active else { return nil }
        return state.last.addingTimeInterval(state.present.isEmpty ? alarm.keepSeconds : alarm.maxSeconds).timeIntervalSince(now())
    }

    /// Visible for tests.
    func endAlarm(_ name: String) {
        guard let alarm = config.alarms.first(where: { $0.name == name }), alarmStates[name]?.active == true else { return }
        alarmStates[name]?.active = false
        alarmStates[name]?.timer = nil
        log(LogEntry(category: "alarm", message: "‘\(name)’ ended"))
        queue(alarm.endSteps, for: alarm)
    }

    private func queue(_ steps: [AlarmStep], for alarm: Alarm) {
        let executor = self.executor, log = self.log, previous = alarmStates[alarm.name]?.chain, name = alarm.name
        let task = Task {
            await previous?.value
            for step in steps {
                do { try await RuleEngine.run(.alarm(step), executor: executor, log: log) }
                catch { log(LogEntry(level: .error, category: "alarm", message: "‘\(name)’ step failed: \(error)")) }
            }
        }
        alarmStates[alarm.name, default: AlarmState()].chain = task
    }

    // MARK: Presence holds

    private func activeHold(pausing rule: Rule) -> (hold: PresenceHold, until: Date)? {
        for hold in config.presence {
            if let until = holdUntil[hold.name], until > now(), rule.isPaused(by: hold) { return (hold, until) }
        }
        return nil
    }

    /// (Re)starts a hold: it now ends `duration` after this trigger.
    private func extend(_ hold: PresenceHold) {
        let until = now().addingTimeInterval(hold.duration)
        let old = holdUntil[hold.name].flatMap { $0 > now() ? $0 : nil }
        // A busy sensor must not rewrite the state file on every event.
        if let old, until.timeIntervalSince(old) < 60 { return }
        holdUntil[hold.name] = until
        holdStore?.save(holdUntil)
        if old == nil {
            log(LogEntry(category: "presence", message: "‘\(hold.name)’: automation paused until \(RuleEngine.format(until)); renewed by each new trigger"))
            // A pending 'off in N minutes' is automation too.
            cancelLutronTimers(hold.pauses.lutron)
            cancelPlugTimers(hold.pauses.plugs)
            for (key, timer) in lightOffTimers where hold.pauses.covers(timer.targets) {
                timer.task.cancel()
                lightOffTimers.removeValue(forKey: key)
                if let name = timer.switchName { onSwitch(name, false) }
            }
        }
        scheduleResume(hold, at: until)
    }

    private func scheduleResume(_ hold: PresenceHold, at until: Date) {
        holdTimers.removeValue(forKey: hold.name)?.cancel()
        let name = hold.name
        holdTimers[name] = Task { [weak self] in
            // Re-check after waking: Mac sleep or a renewed hold can move the deadline.
            while let remaining = await self?.remaining(name), remaining > 0 {
                try? await Task.sleep(for: .seconds(min(remaining, 3600) + 0.5))
                if Task.isCancelled { return }
            }
            await self?.resumed(name)
        }
    }

    private func remaining(_ name: String) -> TimeInterval? { holdUntil[name].map { $0.timeIntervalSince(now()) } }

    /// Visible for tests.
    func resumed(_ name: String) {
        guard let until = holdUntil[name], until <= now() else { return }
        holdUntil.removeValue(forKey: name)
        holdTimers.removeValue(forKey: name)
        holdStore?.save(holdUntil)
        log(LogEntry(category: "presence", message: "‘\(name)’: no trigger for the hold period; automation resumed"))
        if let hold = config.presence.first(where: { $0.name == name }) { reconcile(hold) }
    }

    /// After a hold, put the devices it covered where the automation would have them *now*. Event rules can't say
    /// that, so this uses the schedule rules: for each device, the most recent `at:` rule that should have run
    /// (honouring `days` and `between`) wins and its action is run. Rules marked `on_resume` then run too.
    func reconcile(_ hold: PresenceHold) {
        struct Candidate { var at: Date; var rule: String; var action: Action }
        let current = now()
        let held = Set(hold.pauses.keys)
        var latest: [String: Candidate] = [:]
        for rule in config.rules where rule.enabled {
            guard let schedule = rule.trigger.schedule,
                  let at = schedule.previous(onOrBefore: current, location: config.location),
                  rule.between?.contains(at, location: config.location) ?? true else { continue }
            for action in rule.actions {
                for key in action.targets.keys where held.contains(key) {
                    if let existing = latest[key], existing.at > at { continue }
                    latest[key] = Candidate(at: at, rule: rule.name, action: action)
                }
            }
        }
        // Each action once (it can win for several devices), oldest first so later rules overwrite earlier ones.
        var plan: [(at: Date, rule: String, action: Action)] = []
        for (_, c) in latest.sorted(by: { $0.value.at < $1.value.at }) where !plan.contains(where: { $0.rule == c.rule && "\($0.action)" == "\(c.action)" }) {
            plan.append((c.at, c.rule, c.action))
        }
        for rule in config.rules where rule.enabled && rule.onResume && rule.isPaused(by: hold) {
            for action in rule.actions where hold.pauses.covers(action.targets) { plan.append((current, rule.name, action)) }
        }
        let stillHeld = plan.filter { item in
            config.presence.contains { other in
                other.name != hold.name && (holdUntil[other.name].map { $0 > current } ?? false) && other.pauses.covers(item.action.targets)
            }
        }.map(\.rule)
        let executor = self.executor, log = self.log
        for item in plan where !stillHeld.contains(item.rule) {
            log(LogEntry(category: "presence", message: "restoring from ‘\(item.rule)’ (last due \(RuleEngine.format(item.at)))"))
        }
        let runnable = plan.filter { !stillHeld.contains($0.rule) }.map { ($0.rule, $0.action) }
        Task {
            for (rule, action) in runnable {
                do { try await RuleEngine.run(action, executor: executor, log: log) }
                catch { log(LogEntry(level: .error, category: "presence", message: "restoring from ‘\(rule)’ failed: \(error)")) }
            }
        }
    }

    private func restoreHolds() {
        guard let holdStore else { return }
        let saved = holdStore.load()
        for hold in config.presence {
            guard let until = saved[hold.name], until > now() else { continue }
            holdUntil[hold.name] = until
            log(LogEntry(category: "presence", message: "‘\(hold.name)’: automation still paused until \(RuleEngine.format(until))"))
            scheduleResume(hold, at: until)
        }
        // A hold that ended while HouseBridge was not running still needs its devices put right.
        for hold in config.presence where saved[hold.name].map({ $0 <= now() }) ?? false { reconcile(hold) }
        holdStore.save(holdUntil)   // drops holds that ended or were removed from the config
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm"
        return f.string(from: date)
    }

    private func wantsDoubleTap(_ event: TriggerEvent) -> Bool {
        config.rules.contains { $0.enabled && $0.trigger.kind == "double_tap" && $0.trigger.matches(event, ignoringKind: true) }
    }

    /// UniFi sensors report start/end; `clear` fires once nothing new has happened for a while.
    private func scheduleClear(for event: TriggerEvent) {
        let key = event.key
        if event.kind == "start" {
            clearTasks.removeValue(forKey: key)?.cancel()
        } else if event.kind == "end" {
            clearTasks.removeValue(forKey: key)?.cancel()
            let seconds = config.unifi?.clearAfterSeconds ?? 30
            let cont = continuation
            clearTasks[key] = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                cont.yield(event.with(kind: "clear"))
            }
        }
    }

    private func fire(_ rule: Rule, for event: TriggerEvent) {
        if let (hold, until) = activeHold(pausing: rule) {
            log(LogEntry(category: "rules", message: "‘\(rule.name)’ skipped: paused by ‘\(hold.name)’ until \(RuleEngine.format(until))"))
            return
        }
        if let window = rule.between, !window.contains(Date(), location: config.location) {
            log(LogEntry(category: "rules", message: "‘\(rule.name)’ skipped: outside time window"))
            return
        }
        if rule.cooldownSeconds > 0, let last = lastFired[rule.name],
           Date().timeIntervalSince(last) < rule.cooldownSeconds {
            log(LogEntry(category: "rules", message: "‘\(rule.name)’ skipped: cooldown"))
            return
        }
        lastFired[rule.name] = Date()
        log(LogEntry(category: "rules", message: "‘\(rule.name)’ fired by \(event.summary)"))
        run(rule, holdKey: event.key)
    }

    /// Settles the auto-off timers, then runs the actions in the background.
    private func run(_ rule: Rule, holdKey: String) {
        let executor = self.executor
        let log = self.log
        let actions = rule.actions
        let name = rule.name
        let isScheduled = rule.trigger.schedule != nil

        // Timers are settled here, in order, not inside the task: two rules firing together must not race.
        for action in actions { prepareLightTimer(for: action, keeping: rule.homekitSwitch); armLightTimer(for: action, rule: rule) }

        let task = Task { [weak self] in
            for action in actions {
                if Task.isCancelled { return }
                do {
                    if case .dim(_, _, true, let interval) = action {
                        // Repeat until the button is released.
                        await self?.startRepeating(key: holdKey, action: action, intervalMs: interval, executor: executor, log: log, rule: name)
                        continue
                    }
                    try await RuleEngine.run(action, executor: executor, log: log)
                } catch {
                    log(LogEntry(level: .error, category: "rules", message: "‘\(name)’ action failed: \(error)"))
                    // A scheduled change that did not happen is tried again, not forgotten until the next occurrence.
                    if isScheduled { await self?.scheduleRetry(Set(action.targets.keys), attempt: 0) }
                }
            }
        }
        _ = task
    }

    // MARK: Catch-up of scheduled state

    /// Puts devices where the schedule says they should be *now*, for what edge-triggered `at:` rules can miss: the app
    /// was not running or the Mac was asleep at the time, or the device was unreachable. Only at startup, after wake and
    /// when a scheduled action failed, never on a timer, so a manual change in between is left alone.
    /// Per device the most recent due rule wins, and only if it is a steady state (not `off_after_seconds`, toggles,
    /// dimming). Rules paused by an active presence hold are skipped. `only` limits it to those device keys (retries).
    func catchUp(reason: String, only: Set<String>? = nil, attempt: Int = 0) async {
        struct Candidate { var at: Date; var rule: String; var action: Action; var steady: Bool }
        let current = now()
        var latest: [String: Candidate] = [:]
        for rule in config.rules where rule.enabled {
            guard let schedule = rule.trigger.schedule,
                  let at = schedule.previous(onOrBefore: current, location: config.location),
                  rule.between?.contains(at, location: config.location) ?? true,
                  activeHold(pausing: rule) == nil else { continue }
            for action in rule.actions {
                let steady: Bool
                switch action {
                case .light(_, let state): steady = state.offAfterSeconds == nil
                case .scene: steady = true
                case .lutron(_, _, let off), .plug(_, _, let off): steady = off == nil
                default: steady = false
                }
                for key in action.targets.keys where only?.contains(key) ?? true {
                    if let existing = latest[key], existing.at > at { continue }
                    latest[key] = Candidate(at: at, rule: rule.name, action: action, steady: steady)
                }
            }
        }
        var plan: [(at: Date, rule: String, action: Action, keys: [String])] = []
        for (key, c) in latest.sorted(by: { ($0.value.at, $0.key) < ($1.value.at, $1.key) }) where c.steady {
            if let i = plan.firstIndex(where: { $0.rule == c.rule && "\($0.action)" == "\(c.action)" }) { plan[i].keys.append(key) }
            else { plan.append((c.at, c.rule, c.action, [key])) }
        }
        let executor = self.executor, log = self.log
        var failed = Set<String>()
        for item in plan {
            log(LogEntry(category: "rules", message: "catch-up (\(reason)): ‘\(item.rule)’ was last due \(RuleEngine.format(item.at))"))
            do { try await RuleEngine.run(item.action, executor: executor, log: log) }
            catch {
                log(LogEntry(level: .error, category: "rules", message: "catch-up ‘\(item.rule)’ failed: \(error)"))
                failed.formUnion(item.keys)
            }
        }
        if !failed.isEmpty { scheduleRetry(failed, attempt: attempt) }
    }

    private func scheduleRetry(_ keys: Set<String>, attempt: Int) {
        guard !keys.isEmpty, runner != nil else { return }   // not after stop()
        guard attempt < retryDelays.count else {
            log(LogEntry(level: .error, category: "rules", message: "giving up on \(keys.sorted().joined(separator: ", ")); the next schedule time or restart will try again"))
            return
        }
        retryKeys.formUnion(keys)
        retryTask?.cancel()
        let delay = retryDelays[attempt]
        log(LogEntry(category: "rules", message: "will retry \(retryKeys.sorted().joined(separator: ", ")) in \(Int(delay)) s"))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.retry(attempt: attempt + 1)
        }
    }

    private func retry(attempt: Int) async {
        let keys = retryKeys
        retryKeys = []
        retryTask = nil
        await catchUp(reason: "retry", only: keys, attempt: attempt)
    }

    // MARK: Holiday themes

    private var anyHoldActive: Bool { holdUntil.values.contains { $0 > now() } }

    /// How long after a window ends a missed end step (app asleep or restarted) is still carried out.
    private static let holidayEndGrace: TimeInterval = 3600

    /// Steps that are due at `date` and not in `done`. A start is due from the window's start until its end (so a restart
    /// mid-evening re-applies the colors); an end from the window's end until an hour later. Visible for tests.
    func dueHolidaySteps(at date: Date, done: Set<String>) -> [(key: String, holiday: Holiday, step: HolidayStep)] {
        var out: [(String, Holiday, HolidayStep)] = []
        for h in config.holidays where h.enabled {
            for (start, end) in h.upcoming(after: date.addingTimeInterval(-RuleEngine.holidayEndGrace), location: config.location, days: 3) {
                let stamp = Int(start.timeIntervalSince1970)
                if start <= date, date < end, !done.contains("\(h.name)|\(stamp)|start") {
                    out.append(("\(h.name)|\(stamp)|start", h, .start(colors: h.colors, brightness: h.brightness)))
                }
                if end <= date, date < end.addingTimeInterval(RuleEngine.holidayEndGrace), !done.contains("\(h.name)|\(stamp)|end") {
                    // With someone home the lights may be in use: only the color is reset.
                    out.append(("\(h.name)|\(stamp)|end", h, .end(kelvin: h.normalKelvin, turnOff: !anyHoldActive)))
                }
            }
        }
        return out
    }

    /// The next moment a holiday step could become due, for sleeping.
    private func nextHolidayMoment(after date: Date) -> Date? {
        config.holidays.filter(\.enabled).flatMap { h in
            h.upcoming(after: date, location: config.location, days: 3).flatMap { [$0.start, $0.end] }
        }.filter { $0 > date }.min()
    }

    private func runHolidays() async {
        var done = Set<String>(), skipLogged = Set<String>()
        var announced = false
        while !Task.isCancelled {
            if !announced {
                announced = true
                for h in config.holidays where h.enabled {
                    let next = h.upcoming(after: now(), location: config.location).first.map { "next evening: \(RuleEngine.format($0.start))" } ?? "no dates left"
                    log(LogEntry(category: "holiday", message: "‘\(h.name)’: \(next)"))
                }
            }
            for (key, holiday, step) in dueHolidaySteps(at: now(), done: done) {
                if case .start = step, anyHoldActive {
                    // Not marked done: if the hold ends before the window does, the theme starts then.
                    if skipLogged.insert(key).inserted { log(LogEntry(category: "holiday", message: "‘\(holiday.name)’ waiting: someone is home")) }
                    continue
                }
                done.insert(key)
                log(LogEntry(category: "holiday", message: "‘\(holiday.name)’: \({ if case .start = step { return "lights on in holiday colors" } else { return "back to normal" } }())"))
                do { try await RuleEngine.run(.holiday(step), executor: executor, log: log) }
                catch { log(LogEntry(level: .error, category: "holiday", message: "‘\(holiday.name)’ failed: \(error)")) }
            }
            // Slices, so Mac sleep or a clock change can't leave us waiting far too long.
            let wait = nextHolidayMoment(after: now()).map { $0.timeIntervalSince(now()) } ?? 3600
            try? await Task.sleep(for: .seconds(max(1, min(wait, 600))))
        }
    }

    // MARK: Simulated occupancy

    /// Walks the planned sessions in order, for as long as the engine runs. Plans are deterministic per night,
    /// so a restart picks up the same night; a session already under way is run for its remaining time.
    private func simulate(_ sim: Simulation) async {
        var announced = false
        var fired = Set<Date>()
        while !Task.isCancelled {
            let upcoming = sim.upcoming(after: now(), location: config.location)
            if !announced {
                announced = true
                let next = upcoming.first.map { "next: \(RuleEngine.format($0.start))" } ?? "no sessions in the next week"
                log(LogEntry(category: "simulate", message: "‘\(sim.name)’: \(next)"))
            }
            fired = fired.filter { $0 > now().addingTimeInterval(-86400) }
            guard let session = upcoming.first(where: { !fired.contains($0.start) }) else {
                try? await Task.sleep(for: .seconds(3600)); continue
            }
            let wait = session.start.timeIntervalSince(now())
            if wait > 0 {
                // Slices, so Mac sleep or a clock change can't leave us waiting far too long.
                try? await Task.sleep(for: .seconds(min(wait, 600)))
                continue
            }
            fired.insert(session.start)
            fireSimulated(sim, session)
        }
    }

    /// Visible for tests. Runs one session unless a presence hold covers its lights.
    func fireSimulated(_ sim: Simulation, _ session: SimulatedSession) {
        let remaining = session.end.timeIntervalSince(now())
        guard remaining > 1 else { return }
        let rule = Rule(name: sim.name, trigger: TriggerSpec(source: .clock, kind: "simulate"), actions: [sim.action(for: session, remaining: remaining)])
        if let (hold, until) = activeHold(pausing: rule) {
            log(LogEntry(category: "simulate", message: "‘\(sim.name)’ skipped: paused by ‘\(hold.name)’ until \(RuleEngine.format(until))"))
            return
        }
        log(LogEntry(category: "simulate", message: "‘\(sim.name)’: lights on for \(Int(remaining / 60)) min"))
        run(rule, holdKey: "simulate:\(sim.name)")
    }

    // MARK: Home.app switches

    /// Home.app flipped a switch. On runs the first enabled rule that names it (ignoring its trigger, time window,
    /// cooldown and presence holds, since a person asked), so its `off_after_seconds` applies. Off ends the lights now.
    public func setSwitch(_ name: String, on: Bool) {
        let rules = config.rules.filter { $0.enabled && $0.homekitSwitch?.lowercased() == name.lowercased() }
        guard let rule = rules.first else { return }
        if on {
            log(LogEntry(category: "rules", message: "‘\(rule.name)’ started from Home.app switch ‘\(name)’"))
            run(rule, holdKey: "homekit:\(name)")
            onSwitch(name, true)
        } else {
            log(LogEntry(category: "rules", message: "Home.app switch ‘\(name)’ turned off"))
            for (key, timer) in lightOffTimers where timer.switchName?.lowercased() == name.lowercased() {
                timer.task.cancel()
                lightOffTimers.removeValue(forKey: key)
            }
            let executor = self.executor, log = self.log
            let offs = rules.flatMap(\.actions).compactMap { $0.autoOff?.off }
            Task {
                for off in offs {
                    do { try await executor.execute(off) }
                    catch { log(LogEntry(level: .error, category: "rules", message: "switch ‘\(name)’ off failed: \(error)")) }
                }
            }
            onSwitch(name, false)
        }
    }

    private static func lightKey(_ t: HueTarget) -> String {
        ["light": t.lights, "room": t.rooms, "zone": t.zones]
            .flatMap { kind, names in names.map { "\(kind):\($0.lowercased())" } }.sorted().joined(separator: ",")
    }

    /// Any new command for a light target supersedes its pending auto-off. A switch whose timer is dropped this way
    /// goes off, unless the new command re-arms the same switch.
    private func prepareLightTimer(for action: Action, keeping switchName: String?) {
        guard case .light(let target, _) = action,
              let old = lightOffTimers.removeValue(forKey: RuleEngine.lightKey(target)) else { return }
        old.task.cancel()
        if let name = old.switchName, !(action.autoOff != nil && switchName?.lowercased() == name.lowercased()) { onSwitch(name, false) }
    }

    /// `off_after_seconds` on a `light` action: turn the same lights off after that long, unless re-armed first.
    private func armLightTimer(for action: Action, rule: Rule) {
        guard case .light(let target, let state) = action, let seconds = state.offAfterSeconds, let (_, off) = action.autoOff else { return }
        let key = RuleEngine.lightKey(target)
        let executor = self.executor, log = self.log, name = rule.name, switchName = rule.homekitSwitch
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.lightTimerFired(key)
            do { try await executor.execute(off) }
            catch { log(LogEntry(level: .error, category: "rules", message: "‘\(name)’ auto-off failed: \(error)")) }
        }
        lightOffTimers[key] = (PauseTargets(lights: target.lights, rooms: target.rooms, zones: target.zones), task, switchName, off)
        if let switchName { onSwitch(switchName, true) }
    }

    private func lightTimerFired(_ key: String) {
        if let name = lightOffTimers.removeValue(forKey: key)?.switchName { onSwitch(name, false) }
    }

    private func startRepeating(key: String, action: Action, intervalMs: Int, executor: ActionExecutor,
                                log: @escaping @Sendable (LogEntry) -> Void, rule: String) {
        repeaters.removeValue(forKey: key)?.cancel()
        repeaters[key] = Task {
            while !Task.isCancelled {
                do { try await executor.execute(action) }
                catch { log(LogEntry(level: .error, category: "rules", message: "‘\(rule)’ dim failed: \(error)")); return }
                try? await Task.sleep(for: .milliseconds(intervalMs))
            }
        }
    }

    static func run(_ action: Action, executor: ActionExecutor, log: @Sendable (LogEntry) -> Void) async throws {
        switch action {
        case .wait(let ms): try await Task.sleep(for: .milliseconds(ms))
        case .log(let message): log(LogEntry(category: "rules", message: message))
        default: try await executor.execute(action)
        }
    }
}
