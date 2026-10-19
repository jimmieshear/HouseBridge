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

    public init(config: Config, executor: ActionExecutor,
                onEvent: @escaping @Sendable (TriggerEvent) -> Void = { _ in },
                log: @escaping @Sendable (LogEntry) -> Void) {
        self.config = config
        self.executor = executor
        self.log = log
        self.onEvent = onEvent
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

        for rule in config.rules where rule.enabled && rule.trigger.matches(event) {
            fire(rule, for: event)
        }
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
        if let window = rule.between, !window.contains(Date()) {
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
