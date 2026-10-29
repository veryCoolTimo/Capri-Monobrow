import Foundation

/// Произвольный JSON (payload хуков меняется между версиями агентов — разбираем терпимо).
public enum JSONValue: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
}

public enum Agent: String, Codable, Equatable {
    case claude, codex
}

public struct TmuxRef: Codable, Equatable {
    public var pane: String
    public var session: String?
    public var window: String?
    /// pid процесса панели: tmux переиспользует `%N` после перезапуска сервера.
    public var pid: String?

    public init(pane: String, session: String? = nil, window: String? = nil, pid: String? = nil) {
        self.pane = pane; self.session = session; self.window = window; self.pid = pid
    }
}

/// Одна строка `~/.capri/events.jsonl`, как её пишет capri-hook.
public struct CapriEvent: Codable, Equatable {
    public var v: Int
    /// Уникальный id строки (capri-hook ≥2); у старых записей нет.
    public var id: String?
    public var ts: Double
    public var host: String
    public var agent: Agent
    public var source: String          // "hook" | "notify"
    public var event: String           // имя события хука или тип notify
    public var sessionId: String?
    public var cwd: String?
    public var tmux: TmuxRef?
    public var data: JSONValue

    enum CodingKeys: String, CodingKey {
        case v, id, ts, host, agent, source, event, cwd, tmux, data
        case sessionId = "session_id"
    }

    public static func decode(line: String) -> CapriEvent? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CapriEvent.self, from: d)
    }

    /// Отпечаток для дедупликации при повторной отдаче журнала после переподключения.
    public var fingerprint: String { id ?? "\(sessionId ?? "-")|\(event)|\(ts)" }
}

public struct PaneInfo: Codable, Equatable {
    public var pane: String
    public var session: String
    public var window: String
    public var command: String
    public var pid: String
    public var path: String
    public var title: String
    /// Агент по дереву процессов панели (capri-hook смотрит `ps`), nil — не агент.
    public var agent: Agent?

    public init(pane: String, session: String, window: String = "0", command: String, pid: String = "",
                path: String = "", title: String = "", agent: Agent? = nil) {
        self.pane = pane; self.session = session; self.window = window; self.command = command
        self.pid = pid; self.path = path; self.title = title; self.agent = agent
    }
}

/// Сообщение `capri-hook stream`. `now` — часы хоста: по ним считаем сдвиг относительно Мака.
public enum StreamMessage: Equatable {
    /// Версия протокола, которую понимает этот Capri.
    public static let proto = 1

    case hello(host: String, proto: Int, version: Int, now: Double?)
    case event(CapriEvent, replay: Bool)
    case panes([PaneInfo]?)
    case screen(pane: String, agent: Agent?, lines: [String], ts: Double)
    case snapshotEnd(now: Double?)
    case heartbeat(now: Double?)

    private struct Raw: Decodable {
        var kind: String
        var host: String?
        var replay: Bool?
        var event: CapriEvent?
        var panes: [PaneInfo]?
        var pane: String?
        var agent: Agent?
        var lines: [String]?
        var ts: Double?
        var proto: Int?
        var version: Int?
        var now: Double?
    }

    public static func decode(line: String) -> StreamMessage? {
        guard let d = line.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: d) else { return nil }
        switch raw.kind {
        case "hello": return .hello(host: raw.host ?? "", proto: raw.proto ?? 0, version: raw.version ?? 0, now: raw.now)
        case "event": return raw.event.map { .event($0, replay: raw.replay ?? false) }
        case "panes": return .panes(raw.panes)
        case "screen":
            guard let pane = raw.pane, let lines = raw.lines else { return nil }
            return .screen(pane: pane, agent: raw.agent, lines: lines, ts: raw.ts ?? 0)
        case "snapshot-end": return .snapshotEnd(now: raw.now)
        case "heartbeat": return .heartbeat(now: raw.now)
        default: return nil
        }
    }
}
