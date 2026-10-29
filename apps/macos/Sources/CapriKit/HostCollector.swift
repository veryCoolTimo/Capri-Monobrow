import Foundation

/// Пауза перед переподключением: 1, 2, 4 … 30 с; сбрасывается, если соединение продержалось минуту.
public struct Backoff: Equatable {
    public var attempt = 0
    public let base: Double
    public let cap: Double
    public let stableAfter: Double

    public init(base: Double = 1, cap: Double = 30, stableAfter: Double = 60) {
        self.base = base; self.cap = cap; self.stableAfter = stableAfter
    }

    /// Соединение закрылось, проработав `uptime` секунд. Возвращает паузу до следующей попытки.
    public mutating func next(afterUptime uptime: Double) -> Double {
        if uptime >= stableAfter { attempt = 0 }
        let delay = min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return delay
    }

    public mutating func reset() { attempt = 0 }
}

/// Держит одно соединение `capri-hook stream` и превращает его вывод во входы reducer'а.
///
/// - Переподключается с backoff; молчание дольше `staleAfter` (нет heartbeat) — тоже обрыв.
/// - Время хоста переводит в часы Мака по сдвигу из hello/heartbeat, чтобы reducer сравнивал
///   события, экраны и tick в одной шкале.
/// - События из снимка после **пере**подключения, случившиеся пока связи не было, отдаёт как живые —
///   иначе запрос разрешения, пришедший во время сна Мака, остался бы без уведомления.
/// Работает на главной очереди: создавать и вызывать с главного потока.
public final class HostCollector {
    public let source: HostSource
    public var onInput: ((CapriInput) -> Void)?
    public var onLog: ((String) -> Void)?

    public private(set) var connected = false
    /// Версия capri-hook на хосте из hello (send есть с 3).
    public private(set) var hookVersion = 0
    /// Сдвиг «часы Мака − часы хоста», секунды.
    public private(set) var clockOffset: Double = 0
    private var process: Process?
    private var generation = 0
    private var buffer = Data()
    private var backoff = Backoff()
    private var startedAt = Date()
    private var lastData = Date()
    private var retryWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var stopped = true
    private var lastStderr = ""
    /// Когда связь пропала (часы Мака); nil — ещё ни разу не были подключены.
    private var disconnectedAt: Double?
    private var everConnected = false
    private let staleAfter: TimeInterval = 45

    public init(source: HostSource) { self.source = source }

    public func start() {
        stopped = false
        launch()
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkStale() }
    }

    public func stop() {
        stopped = true
        retryWork?.cancel()
        watchdog?.invalidate()
        terminate()
        setConnected(false)
    }

    /// После пробуждения или смены сети: не ждать backoff, переподключиться сразу.
    public func reconnectNow() {
        guard !stopped else { return }
        log("переподключение по запросу")
        retryWork?.cancel()
        backoff.reset()
        terminate()
        setConnected(false)
        launch()
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        generation += 1
        let gen = generation
        let p = Process()
        let command = source.command(["stream"] + source.streamArgs)
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            // Пустые данные — EOF: снимаем обработчик, иначе он крутится вхолостую.
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(d, generation: gen) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            guard let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.lastStderr = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(proc, generation: gen) }
        }
        buffer = Data()
        lastStderr = ""
        startedAt = Date()
        lastData = Date()
        do {
            try p.run()
            process = p
            log("запуск: \(command.joined(separator: " "))")
        } catch {
            log("не запустился: \(error)")
            detach(p)
            scheduleRetry()
        }
    }

    private func detach(_ p: Process) {
        for pipe in [p.standardOutput, p.standardError].compactMap({ $0 as? Pipe }) {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
        p.terminationHandler = nil
    }

    private func terminate() {
        guard let p = process else { return }
        process = nil
        generation += 1          // данные старого процесса, ещё стоящие в очереди, отбросятся
        detach(p)
        if p.isRunning { p.terminate() }
    }

    private func exited(_ p: Process, generation gen: Int) {
        guard gen == generation, p === process else { return }
        process = nil
        detach(p)
        log("поток закрылся (код \(p.terminationStatus))\(lastStderr.isEmpty ? "" : ": " + lastStderr)")
        setConnected(false)
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !stopped else { return }
        let delay = backoff.next(afterUptime: Date().timeIntervalSince(startedAt))
        log(String(format: "повтор через %.0f с", delay))
        let work = DispatchWorkItem { [weak self] in self?.launch() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func checkStale() {
        guard process != nil, Date().timeIntervalSince(lastData) > staleAfter else { return }
        log("нет данных \(Int(staleAfter)) с — считаю соединение оборванным")
        terminate()
        setConnected(false)
        scheduleRetry()
    }

    private func receive(_ data: Data, generation gen: Int) {
        guard gen == generation, !data.isEmpty else { return }
        lastData = Date()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), let msg = StreamMessage.decode(line: line) else { continue }
            handle(msg)
            if gen != generation { return }   // handle мог оборвать соединение
        }
    }

    private func syncClock(_ hostNow: Double?) {
        guard let hostNow else { return }
        clockOffset = Date().timeIntervalSince1970 - hostNow
    }

    private func handle(_ msg: StreamMessage) {
        let now = Date().timeIntervalSince1970
        switch msg {
        case let .hello(_, proto, version, hostNow):
            guard proto == StreamMessage.proto else {
                log("capri-hook на хосте говорит на протоколе \(proto), Capri ждёт \(StreamMessage.proto) — обновите хук (scripts/install-hooks.sh)")
                terminate()
                setConnected(false)
                scheduleRetry()
                return
            }
            hookVersion = version
            syncClock(hostNow)
            if abs(clockOffset) > 2 { log(String(format: "часы хоста расходятся с Маком на %.1f с — учитываю", clockOffset)) }
        case let .snapshotEnd(hostNow):
            syncClock(hostNow)
            setConnected(true)
        case let .heartbeat(hostNow):
            syncClock(hostNow)
        case let .event(e, replay):
            var e = e
            e.ts += clockOffset
            // Повтор снимка подавляет уведомления, кроме событий, случившихся пока связи не было.
            let missedWhileAway = replay && everConnected && e.ts > (disconnectedAt ?? .infinity)
            onInput?(.event(host: source.name, e, replay: replay && !missedWhileAway))
        case let .panes(panes):
            onInput?(.panes(host: source.name, panes, ts: now))
        case let .screen(pane, agent, lines, ts):
            onInput?(.screen(host: source.name, pane: pane, agent: agent, lines: lines, ts: ts + clockOffset))
        }
    }

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        if value { everConnected = true } else { disconnectedAt = Date().timeIntervalSince1970 }
        onInput?(.connection(host: source.name, connected: value, ts: Date().timeIntervalSince1970))
        log(value ? "подключено" : "отключено")
    }

    private func log(_ s: String) { onLog?("[\(source.name)] \(s)") }
}
