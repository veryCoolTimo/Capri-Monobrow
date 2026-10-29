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

/// Откуда брать поток событий одного хоста.
public struct HostSource: Equatable {
    public var name: String
    /// Полная команда: локально `python3 ~/.capri/bin/capri-hook stream`, удалённо через ssh.
    public var command: [String]

    public init(name: String, command: [String]) { self.name = name; self.command = command }

    public static let defaultRemoteCommand = "python3 ~/.capri/bin/capri-hook stream"

    public static func local(name: String = "local", hookCommand: String? = nil) -> HostSource {
        let cmd = hookCommand ?? "/usr/bin/python3 \"$HOME/.capri/bin/capri-hook\" stream"
        return HostSource(name: name, command: ["/bin/sh", "-c", "exec " + cmd])
    }

    public static func ssh(_ host: String, name: String? = nil, remoteCommand: String = defaultRemoteCommand) -> HostSource {
        HostSource(name: name ?? host, command: [
            "/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", host, remoteCommand,
        ])
    }
}

/// Держит одно соединение `capri-hook stream` и превращает его вывод во входы reducer'а.
/// Переподключается с backoff; молчание дольше `staleAfter` (нет heartbeat) — тоже обрыв.
/// Колбэки вызываются на главной очереди.
public final class HostCollector {
    public let source: HostSource
    public var onInput: ((CapriInput) -> Void)?
    public var onLog: ((String) -> Void)?

    public private(set) var connected = false
    private var process: Process?
    private var buffer = Data()
    private var backoff = Backoff()
    private var startedAt = Date()
    private var lastData = Date()
    private var retryWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var stopped = true
    private var lastStderr = ""
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
        launch()
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: source.command[0])
        p.arguments = Array(source.command.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { self?.receive(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.lastStderr = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(proc) }
        }
        buffer = Data()
        startedAt = Date()
        lastData = Date()
        do {
            try p.run()
            process = p
            log("запуск: \(source.command.joined(separator: " "))")
        } catch {
            log("не запустился: \(error)")
            scheduleRetry()
        }
    }

    private func terminate() {
        guard let p = process else { return }
        process = nil
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        p.terminationHandler = nil
        if p.isRunning { p.terminate() }
    }

    private func exited(_ p: Process) {
        guard p === process else { return }
        process = nil
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

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lastData = Date()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8), let msg = StreamMessage.decode(line: line) else { continue }
            handle(msg)
        }
    }

    private func handle(_ msg: StreamMessage) {
        let now = Date().timeIntervalSince1970
        switch msg {
        case .hello:
            break
        case .snapshotEnd:
            setConnected(true)
        case .heartbeat:
            break
        case let .event(e, replay):
            onInput?(.event(host: source.name, e, replay: replay))
        case let .panes(panes):
            onInput?(.panes(host: source.name, panes, ts: now))
        case let .screen(pane, agent, lines, ts):
            onInput?(.screen(host: source.name, pane: pane, agent: agent, lines: lines, ts: ts))
        }
    }

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        onInput?(.connection(host: source.name, connected: value, ts: Date().timeIntervalSince1970))
        log(value ? "подключено" : "отключено")
    }

    private func log(_ s: String) { onLog?("[\(source.name)] \(s)") }
}
