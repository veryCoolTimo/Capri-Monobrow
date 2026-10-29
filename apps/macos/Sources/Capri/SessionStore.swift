import AppKit
import CapriKit

/// Живое состояние для интерфейса: сборщики хостов → SessionReducer → сессии для notch;
/// отправка ответов с проверкой доставки. Всё на главном потоке.
final class SessionStore: ObservableObject {
    struct HostRow: Identifiable, Equatable {
        var name: String
        var connected: Bool
        var id: String { name }
    }

    /// Судьба последнего ответа в сессию.
    enum Delivery: Equatable {
        case sending
        /// Хост принял ввод; ждём подтверждения по событию или экрану.
        case sent(at: Double, status: SessionStatus, lastEvent: Double, timeout: Double)
        case delivered
        case refused(String)
        case notDelivered
    }

    /// Не закрытые сессии: сначала ждущие (самые старые сверху), потом остальные по свежести.
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var hosts: [HostRow] = []
    @Published private(set) var deliveries: [SessionKey: Delivery] = [:]
    @Published private(set) var now = Date().timeIntervalSince1970

    var waiting: [Session] { sessions.filter { $0.status == .needsInput } }
    var runningCount: Int { sessions.filter { $0.status == .running }.count }
    /// Есть что показать в свёрнутом notch.
    var active: Bool { sessions.contains { $0.status == .needsInput || $0.status == .running } }

    var onNeedsInput: ((Session) -> Void)?
    var onDelivered: ((SessionKey) -> Void)?

    private var state = CapriState()
    private var supervisor: CollectorSupervisor!
    private var timer: Timer?
    private let journal = CapriPaths.dir.appendingPathComponent("replies.jsonl")

    static let textTimeout: Double = 5
    /// Отказ в Claude хука не даёт: подтверждение приходит по экрану (снимок раз в 2 с + пауза 3 с).
    static let chooseTimeout: Double = 8

    init(sources: [HostSource]) {
        supervisor = CollectorSupervisor(sources: sources) { [weak self] in self?.feed($0) }
        supervisor.onLog = { NSLog("[Capri] %@", $0) }
        hosts = sources.map { HostRow(name: $0.name, connected: false) }
    }

    func start() {
        supervisor.start()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.feed(.tick(Date().timeIntervalSince1970))
        }
    }

    func stop() {
        timer?.invalidate()
        supervisor.stop()
    }

    func session(_ key: SessionKey) -> Session? { resolve(key).flatMap { state.sessions[$0] } }

    /// Ключ сессии с учётом склейки: `pane:%N` (видели по экрану) заменяется сессией из хуков в той же панели.
    func resolve(_ key: SessionKey) -> SessionKey? {
        if let s = state.sessions[key], s.status != .ended { return key }
        guard key.id.hasPrefix("pane:") else { return nil }
        return state.sessions.values.first { $0.key.host == key.host && $0.status != .ended && "pane:" + ($0.tmux?.pane ?? "") == key.id }?.key
    }

    static func displayHost(_ name: String) -> String { name == "local" ? "mac" : name }

    // MARK: состояние

    private func feed(_ input: CapriInput) {
        let before = state
        let effects = SessionReducer.reduce(&state, input)
        if case .tick(let t) = input { now = t; expireDeliveries() }
        if state.sessions != before.sessions { publishSessions() }
        if state.hosts != before.hosts {
            hosts = supervisor.collectors.map { c in HostRow(name: c.source.name, connected: state.hosts[c.source.name]?.connected ?? false) }
        }
        for case let .notifyNeedsInput(key) in effects {
            if let s = state.sessions[key] { onNeedsInput?(s) }
        }
    }

    private func publishSessions() {
        sessions = state.sessions.values
            .filter { $0.status != .ended }
            .sorted { a, b in
                let wa = a.status == .needsInput, wb = b.status == .needsInput
                if wa != wb { return wa }
                if wa { return a.statusSince < b.statusSince }
                return a.lastEventAt > b.lastEventAt
            }
        confirmDeliveries()
    }

    // MARK: ответ

    func check(_ key: SessionKey, _ action: ReplyAction) -> ReplyRefusal? {
        guard let key = resolve(key), let s = state.sessions[key] else { return .paneGone }
        if deliveries[key] == .sending { return .busy }
        let c = collector(key.host)
        return Reply.check(s, action, hostConnected: c?.connected ?? false, hookVersion: c?.hookVersion ?? 0)
    }

    func send(_ key: SessionKey, _ action: ReplyAction, completion: ((Bool) -> Void)? = nil) {
        let key = resolve(key) ?? key
        if let r = check(key, action) {
            deliveries[key] = .refused(r.message)
            record(key, action, result: "refused:\(r)")
            completion?(false)
            return
        }
        guard let s = state.sessions[key], let c = collector(key.host), let args = Reply.arguments(s, action) else {
            completion?(false)
            return
        }
        deliveries[key] = .sending
        HostCommand.run(c.source.command(args), stdin: Reply.stdin(action), timeout: 15) { [weak self] out in
            guard let self else { return }
            if let r = Reply.parseResult(out) {
                self.deliveries[key] = .refused(r.message)
                self.record(key, action, result: "refused:\(r)")
                completion?(false)
                return
            }
            let timeout: Double
            if case .choose = action { timeout = Self.chooseTimeout } else { timeout = Self.textTimeout }
            // Точка отсчёта — состояние до отправки: хук может прийти раньше, чем ssh вернёт ответ.
            self.deliveries[key] = .sent(at: Date().timeIntervalSince1970, status: s.status,
                                         lastEvent: s.lastEventAt, timeout: timeout)
            self.record(key, action, result: "sent")
            self.confirmDeliveries()
            completion?(true)
        }
    }

    func clearDelivery(_ key: SessionKey) {
        if case .sending = deliveries[key] { return }
        deliveries[key] = nil
    }

    private func collector(_ host: String) -> HostCollector? {
        supervisor.collectors.first { $0.source.name == host }
    }

    /// Доставлено, когда сессия сменила статус или пришло новое событие хука.
    private func confirmDeliveries() {
        for (key, d) in deliveries {
            guard case let .sent(_, status, lastEvent, _) = d else { continue }
            guard let s = state.sessions[key] else { deliveries[key] = .delivered; continue }
            if s.status != status || s.lastEventAt > lastEvent {
                deliveries[key] = .delivered
                onDelivered?(key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    if self?.deliveries[key] == .delivered { self?.deliveries[key] = nil }
                }
            }
        }
    }

    private func expireDeliveries() {
        for (key, d) in deliveries {
            if case let .sent(at, _, _, timeout) = d, now - at > timeout {
                deliveries[key] = .notDelivered
                record(key, nil, result: "not-confirmed")
            }
        }
    }

    /// Журнал отправок: кто, куда, что за действие и чем кончилось. Текст ответа не пишем — только длину.
    private func record(_ key: SessionKey, _ action: ReplyAction?, result: String) {
        var rec: [String: Any] = ["ts": Date().timeIntervalSince1970, "host": key.host, "agent": key.agent.rawValue,
                                  "session": key.id, "result": result]
        if let pane = state.sessions[key]?.tmux?.pane { rec["pane"] = pane }
        switch action {
        case .text(let t): rec["action"] = "text"; rec["chars"] = t.count
        case .choose(let n): rec["action"] = "choose"; rec["choice"] = n
        case nil: break
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]) else { return }
        CapriPaths.ensureDir()
        let path = journal.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile()
        h.write(data + Data("\n".utf8))
        try? h.close()
    }
}

/// `~/.capri` на Маке — только для владельца.
enum CapriPaths {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".capri")

    static func ensureDir() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
