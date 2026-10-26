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
    /// When each presence hold ends (only entries still in the future matter).
    private var holdUntil: [String: Date] = [:]
    private var holdTimers: [String: Task<Void, Never>] = [:]
    /// Pending `off_after_seconds` timers for Hue lights, by target. A later action on the same target replaces or cancels it.
    private var lightOffTimers: [String: (targets: PauseTargets, task: Task<Void, Never>)] = [:]
    private let holdStore: HoldStore?
    private let cancelLutronTimers: @Sendable ([String]) -> Void
    private let now: @Sendable () -> Date

    public init(config: Config, executor: ActionExecutor,
                onEvent: @escaping @Sendable (TriggerEvent) -> Void = { _ in },
                holdStore: HoldStore? = nil,
                cancelLutronTimers: @escaping @Sendable ([String]) -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (LogEntry) -> Void) {
        self.config = config
        self.executor = executor
        self.log = log
        self.onEvent = onEvent
        self.holdStore = holdStore
        self.cancelLutronTimers = cancelLutronTimers
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
        holdTimers.values.forEach { $0.cancel() }
        holdTimers = [:]
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
        for rule in config.rules where rule.enabled && rule.trigger.matches(event) {
            fire(rule, for: event)
        }
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
            for (key, timer) in lightOffTimers where hold.pauses.covers(timer.targets) {
                timer.task.cancel()
                lightOffTimers.removeValue(forKey: key)
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

        let executor = self.executor
        let log = self.log
        let actions = rule.actions
        let name = rule.name
        let holdKey = event.key

        // Timers are settled here, in order, not inside the task: two rules firing together must not race.
        for action in actions { prepareLightTimer(for: action); armLightTimer(for: action, rule: name) }

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
                }
            }
        }
        _ = task
    }

    private static func lightKey(_ t: HueTarget) -> String {
        ["light": t.lights, "room": t.rooms, "zone": t.zones]
            .flatMap { kind, names in names.map { "\(kind):\($0.lowercased())" } }.sorted().joined(separator: ",")
    }

    /// Any new command for a light target supersedes its pending auto-off.
    private func prepareLightTimer(for action: Action) {
        guard case .light(let target, _) = action else { return }
        lightOffTimers.removeValue(forKey: RuleEngine.lightKey(target))?.task.cancel()
    }

    /// `off_after_seconds` on a `light` action: turn the same lights off after that long, unless re-armed first.
    private func armLightTimer(for action: Action, rule: String) {
        guard case .light(let target, let state) = action, state.on == true, let seconds = state.offAfterSeconds else { return }
        let key = RuleEngine.lightKey(target)
        let executor = self.executor, log = self.log
        let off = Action.light(target, LightState(on: false, transitionMs: state.transitionMs))
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.lightTimerFired(key)
            do { try await executor.execute(off) }
            catch { log(LogEntry(level: .error, category: "rules", message: "‘\(rule)’ auto-off failed: \(error)")) }
        }
        lightOffTimers[key] = (PauseTargets(lights: target.lights, rooms: target.rooms, zones: target.zones), task)
    }

    private func lightTimerFired(_ key: String) { lightOffTimers.removeValue(forKey: key) }

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
