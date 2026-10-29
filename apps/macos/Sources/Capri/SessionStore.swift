import AppKit
import CapriKit

/// Секундные часы для таймеров «сколько ждёт» — отдельно, чтобы тик не перерисовывал всю панель.
final class Clock: ObservableObject {
    @Published var now = Date().timeIntervalSince1970
}

/// Живое состояние для интерфейса: сборщики хостов → SessionReducer → сессии для notch;
/// отправка ответов с проверкой доставки. Всё на главном потоке.
final class SessionStore: ObservableObject {
    struct HostRow: Identifiable, Equatable {
        var name: String
        var connected: Bool
        var id: String { name }
    }

    /// Не закрытые сессии: сначала ждущие (самые старые сверху), потом остальные по свежести.
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var hosts: [HostRow] = []
    @Published private(set) var deliveries = DeliveryTracker()
    let clock = Clock()

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
    func resolve(_ key: SessionKey) -> SessionKey? { state.resolve(key) }

    /// Как достучаться до хоста сессии (для «Открыть»).
    func transport(_ host: String) -> HostSource.Transport? { collector(host)?.source.transport }

    static func displayHost(_ name: String) -> String { name == "local" ? "mac" : name }

    // MARK: состояние

    private func feed(_ input: CapriInput) {
        let before = state
        let effects = SessionReducer.reduce(&state, input)
        if case .tick(let t) = input {
            clock.now = t
            for key in deliveries.expire(now: t) { record(key, nil, result: "not-confirmed") }
        }
        if state.sessions != before.sessions {
            publishSessions()
            confirmDeliveries()
        }
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
    }

    // MARK: ответ

    func check(_ key: SessionKey, _ action: ReplyAction) -> ReplyRefusal? {
        guard let key = resolve(key), let s = state.sessions[key] else { return .paneGone }
        if deliveries.isBusy(key) { return .busy }
        let c = collector(key.host)
        return Reply.check(s, action, hostConnected: c?.connected ?? false, hookVersion: c?.hookVersion ?? 0)
    }

    func send(_ key: SessionKey, _ action: ReplyAction, completion: ((Bool) -> Void)? = nil) {
        let key = resolve(key) ?? key
        if let r = check(key, action) {
            deliveries.refused(key, r.message)
            record(key, action, result: "refused:\(r)")
            completion?(false)
            return
        }
        guard let s = state.sessions[key], let c = collector(key.host), let args = Reply.arguments(s, action) else {
            completion?(false)
            return
        }
        deliveries.sending(key)
        HostCommand.run(c.source.command(args), stdin: Reply.stdin(s, action), timeout: 15) { [weak self] out in
            guard let self else { return }
            if let r = Reply.parseResult(out) {
                self.deliveries.refused(key, r.message)
                self.record(key, action, result: "refused:\(r)")
                completion?(false)
                return
            }
            // Точка отсчёта — сессия до отправки: хук может прийти раньше, чем ssh вернёт ответ.
            self.deliveries.sent(key, before: s, action: action, at: Date().timeIntervalSince1970)
            self.record(key, action, result: "sent")
            self.confirmDeliveries()
            completion?(true)
        }
    }

    func clearDelivery(_ key: SessionKey) { deliveries.clear(key) }

    private func collector(_ host: String) -> HostCollector? {
        supervisor.collectors.first { $0.source.name == host }
    }

    private func confirmDeliveries() {
        for key in deliveries.update(state.sessions, resolve: state.resolve) {
            onDelivered?(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.deliveries.dropDelivered(key) }
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
    static let tmp = dir.appendingPathComponent("tmp")

    /// Создаёт `~/.capri` и `~/.capri/tmp` с 0700 и ужесточает права, если каталоги остались от старой версии.
    static func ensureDir() {
        for d in [dir, tmp] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let mode = (try? FileManager.default.attributesOfItem(atPath: d.path))?[.posixPermissions] as? Int, mode & 0o077 != 0 {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
            }
        }
    }

    /// Неиспользованные `.command` от «Открыть» (Terminal не запустил) — убрать старше часа.
    static func cleanTmp() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasSuffix(".command") {
            let path = tmp.appendingPathComponent(name).path
            if let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, Date().timeIntervalSince(date) > 3600 {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
