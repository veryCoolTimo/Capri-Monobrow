import Foundation

public enum SessionStatus: String, Codable, Equatable {
    case running, needsInput = "needs_input", idle, error, rateLimited = "rate_limited", ended, unknown
}

public enum Confidence: String, Codable, Equatable {
    case hook, inferred
}

public struct SessionKey: Hashable, Codable, CustomStringConvertible {
    public var host: String
    public var agent: Agent
    /// session_id из хуков или `pane:%5` для сессии, видимой только по экрану.
    public var id: String

    public init(host: String, agent: Agent, id: String) { self.host = host; self.agent = agent; self.id = id }
    public var description: String { "\(host)/\(agent.rawValue)/\(id)" }
}

/// Чего сессия ждёт: запрос разрешения, вопрос с вариантами или уведомление без деталей.
public struct PendingRequest: Codable, Equatable {
    public enum Kind: String, Codable { case permission, question, notification }
    public var kind: Kind
    public var tool: String?
    /// Коротко для notch: команда, вопрос или текст уведомления.
    public var summary: String
    public var options: [String]

    public init(kind: Kind, tool: String? = nil, summary: String, options: [String] = []) {
        self.kind = kind; self.tool = tool; self.summary = summary; self.options = options
    }
}

public struct Session: Codable, Equatable {
    public var key: SessionKey
    public var tmux: TmuxRef?
    public var cwd: String?
    public var status: SessionStatus
    public var confidence: Confidence
    public var statusSince: Double
    public var lastEventAt: Double
    public var request: PendingRequest?
    public var lastMessage: String?
    /// Набранный, но не отправленный текст в строке ввода (по экрану). Нужен, чтобы не вписать ответ поверх.
    public var typedInput: String?

    public var project: String { cwd.map { ($0 as NSString).lastPathComponent } ?? key.id }
}

public struct HostState: Codable, Equatable {
    public var connected: Bool
    public var since: Double
    public var panes: [PaneInfo]?
}

public struct CapriState: Equatable {
    public var sessions: [SessionKey: Session] = [:]
    public var hosts: [String: HostState] = [:]
    /// Отпечатки уже применённых событий (повтор журнала после переподключения).
    var seen: Set<String> = []
    var seenOrder: [String] = []
    /// Экран показал «ждёт ввода», пока по хукам сессия работает/ждёт: подтверждаем через паузу.
    var pendingIdle: [SessionKey: Double] = [:]

    public init() {}

    /// «Ждут меня» для notch: сверху самые старые.
    public var waiting: [Session] {
        sessions.values.filter { $0.status == .needsInput }.sorted { $0.statusSince < $1.statusSince }
    }
}

public enum CapriInput: Equatable {
    case event(host: String, CapriEvent, replay: Bool)
    case screen(host: String, pane: String, agent: Agent?, lines: [String], ts: Double)
    case panes(host: String, [PaneInfo]?, ts: Double)
    case connection(host: String, connected: Bool, ts: Double)
    case tick(Double)
}

public enum CapriEffect: Equatable {
    /// Сессия перешла в «ждёт меня» — одно уведомление на переход.
    case notifyNeedsInput(SessionKey)
}

public enum SessionReducer {
    /// Сколько экран должен стабильно показывать «ждёт ввода», чтобы перебить статус из хуков
    /// (экран снимается раз в 2 с — пауза длиннее интервала снимков).
    public static let screenIdleGrace: Double = 3.0
    /// Снимок, сделанный сразу после смены статуса, мог не успеть отразить её — такой не учитываем.
    public static let screenLag: Double = 1.0
    static let titlePromptPrefix = "Generate a concise, single-line task title"
    static let seenLimit = 5000

    @discardableResult
    public static func reduce(_ state: inout CapriState, _ input: CapriInput) -> [CapriEffect] {
        switch input {
        case let .event(host, event, replay):
            return apply(&state, host: host, event: event, replay: replay)
        case let .screen(host, pane, agent, lines, ts):
            return applyScreen(&state, host: host, pane: pane, agent: agent, lines: lines, ts: ts)
        case let .panes(host, panes, ts):
            applyPanes(&state, host: host, panes: panes, ts: ts)
            return []
        case let .connection(host, connected, ts):
            var h = state.hosts[host] ?? HostState(connected: connected, since: ts, panes: nil)
            if h.connected != connected || state.hosts[host] == nil { h.since = ts }
            h.connected = connected
            state.hosts[host] = h
            return []
        case let .tick(now):
            return applyTick(&state, now: now)
        }
    }

    // MARK: события хуков

    static func apply(_ state: inout CapriState, host: String, event e: CapriEvent, replay: Bool) -> [CapriEffect] {
        guard let sid = e.sessionId, !sid.isEmpty else { return [] }
        let fp = "\(host)|\(e.agent.rawValue)|\(e.fingerprint)"
        guard !state.seen.contains(fp) else { return [] }
        remember(&state, fp)

        let key = SessionKey(host: host, agent: e.agent, id: sid)
        if e.source == "notify" {
            return applyNotify(&state, key: key, event: e, replay: replay)
        }
        var s = state.sessions[key] ?? Session(key: key, tmux: e.tmux, cwd: e.cwd, status: .unknown, confidence: .hook,
                                               statusSince: e.ts, lastEventAt: e.ts, request: nil, lastMessage: nil, typedInput: nil)
        // Устаревшее событие (пришло после более нового) не откатывает статус.
        if e.ts < s.lastEventAt { return [] }
        s.lastEventAt = e.ts
        if let t = e.tmux { s.tmux = t }
        if let c = e.cwd { s.cwd = c }
        let before = s.status

        switch e.event {
        case "SessionStart":
            if e.data["source"]?.string != "compact" || s.status == .unknown { set(&s, .idle, e.ts) }
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            set(&s, .running, e.ts); s.request = nil
        case "PermissionRequest":
            set(&s, .needsInput, e.ts); s.request = request(from: e.data)
        case "Notification":
            let type = e.data["notification_type"]?.string ?? ""
            if type == "permission_prompt" || type.contains("elicitation") {
                if s.status != .needsInput {
                    set(&s, .needsInput, e.ts)
                    s.request = PendingRequest(kind: .notification, summary: e.data["message"]?.string ?? "Нужен ответ")
                }
            } else if type == "idle_prompt", s.status == .running {
                set(&s, .idle, e.ts)
            }
        case "Stop", "Interrupt":
            set(&s, .idle, e.ts); s.request = nil
            if let m = e.data["last_assistant_message"]?.string { s.lastMessage = m }
        case "StopFailure":
            let err = e.data["error"]?.string ?? ""
            set(&s, err.contains("rate") ? .rateLimited : .error, e.ts); s.request = nil
            s.lastMessage = e.data["last_assistant_message"]?.string ?? err
        case "SessionEnd":
            set(&s, .ended, e.ts); s.request = nil
        default:
            break
        }
        s.confidence = .hook
        state.pendingIdle[key] = nil
        state.sessions[key] = s
        // Хуки пришли из панели, где раньше видели сессию только по экрану, — она та же.
        if let pane = s.tmux?.pane {
            let inferred = SessionKey(host: host, agent: e.agent, id: "pane:\(pane)")
            state.sessions[inferred] = nil
            state.pendingIdle[inferred] = nil
        }
        return transitionEffects(key: key, before: before, after: s.status, replay: replay)
    }

    static func applyNotify(_ state: inout CapriState, key: SessionKey, event e: CapriEvent, replay: Bool) -> [CapriEffect] {
        // Служебный ход Codex (генерация заголовка) и notify неизвестных тредов не учитываем.
        let first = e.data["input-messages"]?.array?.first?.string ?? ""
        guard !first.hasPrefix(titlePromptPrefix), var s = state.sessions[key], e.ts >= s.lastEventAt else { return [] }
        let before = s.status
        if s.status == .running {
            set(&s, .idle, e.ts)
            s.lastMessage = e.data["last-assistant-message"]?.string ?? s.lastMessage
        }
        s.lastEventAt = e.ts
        state.sessions[key] = s
        return transitionEffects(key: key, before: before, after: s.status, replay: replay)
    }

    static func request(from data: JSONValue) -> PendingRequest {
        let tool = data["tool_name"]?.string
        let input = data["tool_input"]
        if tool == "AskUserQuestion", let q = input?["questions"]?.array?.first {
            let options = q["options"]?.array?.compactMap { $0["label"]?.string } ?? []
            return PendingRequest(kind: .question, tool: tool, summary: q["question"]?.string ?? "Вопрос", options: options)
        }
        let summary = input?["command"]?.string ?? input?["description"]?.string ?? input?["file_path"]?.string ?? tool ?? "Разрешение"
        return PendingRequest(kind: .permission, tool: tool, summary: summary)
    }

    // MARK: экран (фолбэк)

    static func applyScreen(_ state: inout CapriState, host: String, pane: String, agent paneAgent: Agent?, lines: [String], ts: Double) -> [CapriEffect] {
        let hooked = state.sessions.values
            .filter { $0.key.host == host && $0.tmux?.pane == pane && $0.status != .ended && !$0.key.id.hasPrefix("pane:") }
            .max { $0.lastEventAt < $1.lastEventAt }
        let agent = hooked?.key.agent ?? paneAgent
        let screen = ScreenClassifier.classify(lines: lines, agent: agent)

        if var s = hooked {
            let key = s.key
            let before = s.status
            switch screen {
            case .idle(let typed):
                s.typedInput = typed
                if (s.status == .running || s.status == .needsInput) && ts >= s.statusSince + screenLag {
                    if state.pendingIdle[key] == nil { state.pendingIdle[key] = ts }
                }
            case .dialog(let d):
                state.pendingIdle[key] = nil
                if s.status == .running || s.status == .idle {
                    set(&s, .needsInput, ts); s.confidence = .inferred
                    s.request = PendingRequest(kind: d.kind == .question ? .question : .permission,
                                               summary: d.title ?? "Нужен ответ", options: d.options.map { "\($0.key) \($0.label)" })
                }
            case .running:
                state.pendingIdle[key] = nil
                s.typedInput = nil
            case .unknown:
                break
            }
            state.sessions[key] = s
            return transitionEffects(key: key, before: before, after: s.status, replay: false)
        }

        // Сессия без хуков: видна только по экрану.
        guard let agent else { return [] }
        let key = SessionKey(host: host, agent: agent, id: "pane:\(pane)")
        var s = state.sessions[key] ?? Session(key: key, tmux: TmuxRef(pane: pane), cwd: nil, status: .unknown,
                                               confidence: .inferred, statusSince: ts, lastEventAt: ts,
                                               request: nil, lastMessage: nil, typedInput: nil)
        let before = s.status
        switch screen {
        case .running: set(&s, .running, ts); s.request = nil; s.typedInput = nil
        case .dialog(let d):
            set(&s, .needsInput, ts)
            s.request = PendingRequest(kind: d.kind == .question ? .question : .permission,
                                       summary: d.title ?? "Нужен ответ", options: d.options.map { "\($0.key) \($0.label)" })
        case .idle(let typed): set(&s, .idle, ts); s.request = nil; s.typedInput = typed
        case .unknown: break
        }
        s.lastEventAt = ts
        if let p = state.hosts[host]?.panes?.first(where: { $0.pane == pane }) {
            s.tmux = TmuxRef(pane: pane, session: p.session, window: p.window)
            if !p.path.isEmpty { s.cwd = p.path }
        }
        state.sessions[key] = s
        return transitionEffects(key: key, before: before, after: s.status, replay: false)
    }

    static func applyTick(_ state: inout CapriState, now: Double) -> [CapriEffect] {
        for (key, since) in state.pendingIdle where now - since >= screenIdleGrace {
            state.pendingIdle[key] = nil
            guard var s = state.sessions[key], s.status == .running || s.status == .needsInput,
                  s.lastEventAt <= since else { continue }
            set(&s, .idle, since)
            s.request = nil
            s.confidence = .inferred
            state.sessions[key] = s
        }
        return []
    }

    static func applyPanes(_ state: inout CapriState, host: String, panes: [PaneInfo]?, ts: Double) {
        var h = state.hosts[host] ?? HostState(connected: true, since: ts, panes: nil)
        h.panes = panes
        state.hosts[host] = h
        // panes == nil — tmux не ответил; ничего не закрываем.
        guard let panes else { return }
        let alive = Set(panes.map(\.pane))
        for (key, s) in state.sessions where key.host == host && s.status != .ended {
            guard let pane = s.tmux?.pane, !alive.contains(pane) else { continue }
            if key.id.hasPrefix("pane:") {
                state.sessions[key] = nil
            } else {
                var e = s
                set(&e, .ended, ts)
                e.request = nil
                state.sessions[key] = e
            }
            state.pendingIdle[key] = nil
        }
    }

    // MARK: помощники

    static func set(_ s: inout Session, _ status: SessionStatus, _ ts: Double) {
        if s.status != status {
            s.status = status
            s.statusSince = ts
        }
    }

    static func transitionEffects(key: SessionKey, before: SessionStatus, after: SessionStatus, replay: Bool) -> [CapriEffect] {
        (!replay && after == .needsInput && before != .needsInput) ? [.notifyNeedsInput(key)] : []
    }

    static func remember(_ state: inout CapriState, _ fp: String) {
        state.seen.insert(fp)
        state.seenOrder.append(fp)
        if state.seenOrder.count > seenLimit {
            let drop = state.seenOrder.prefix(state.seenOrder.count - seenLimit)
            drop.forEach { state.seen.remove($0) }
            state.seenOrder.removeFirst(drop.count)
        }
    }
}
