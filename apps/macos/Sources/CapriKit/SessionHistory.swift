import Foundation

/// Строка истории сессии для основного окна.
public struct HistoryEntry: Equatable, Identifiable {
    public enum Kind: Equatable { case info, attention, tools, reply, problem }
    public var id: Int
    public var ts: Double
    public var kind: Kind
    public var text: String
    /// Для `.tools`: сколько вызовов слито в строку и какие инструменты.
    var toolCount = 0
    var tools: [String] = []
}

/// Короткая история событий по сессиям: из хуков и из ответов Capri. Только в памяти, ограниченная.
/// Подряд идущие вызовы инструментов (PostToolUse) сливаются в одну строку.
public struct SessionHistory: Equatable {
    public static let perSession = 60
    static let seenLimit = 5000

    public private(set) var entries: [SessionKey: [HistoryEntry]] = [:]
    private var nextId = 0
    private var seen: Set<String> = []
    private var seenOrder: [String] = []

    public init() {}

    public func list(_ key: SessionKey) -> [HistoryEntry] { entries[key] ?? [] }

    /// Событие хука. Повтор журнала после переподключения отбрасывается по отпечатку.
    public mutating func record(host: String, event e: CapriEvent) {
        guard let sid = e.sessionId, !sid.isEmpty else { return }
        let fp = "\(host)|\(e.agent.rawValue)|\(e.fingerprint)"
        guard !seen.contains(fp) else { return }
        seen.insert(fp); seenOrder.append(fp)
        if seenOrder.count > Self.seenLimit {
            for old in seenOrder.prefix(seenOrder.count - Self.seenLimit) { seen.remove(old) }
            seenOrder.removeFirst(seenOrder.count - Self.seenLimit)
        }
        let key = SessionKey(host: host, agent: e.agent, id: sid)
        if e.event == "PostToolUse" || e.event == "PreToolUse" {
            tool(key, ts: e.ts, name: e.data["tool_name"]?.string ?? "?")
            return
        }
        guard let (kind, text) = Self.describe(e) else { return }
        append(key, ts: e.ts, kind: kind, text: text)
    }

    /// Запись от самого Capri: ответ, выбор варианта, отказ.
    public mutating func note(_ key: SessionKey, ts: Double, kind: HistoryEntry.Kind, text: String) {
        append(key, ts: ts, kind: kind, text: text)
    }

    /// Убрать истории сессий, которых больше нет.
    public mutating func keep(only keys: Set<SessionKey>) {
        for k in entries.keys where !keys.contains(k) { entries[k] = nil }
    }

    static func describe(_ e: CapriEvent) -> (HistoryEntry.Kind, String)? {
        let d = e.data
        func first(_ s: String?) -> String? {
            guard let s, let line = s.split(whereSeparator: \.isNewline).first else { return nil }
            return String(line.prefix(160))
        }
        if e.source == "notify" {
            guard e.data["type"]?.string == "agent-turn-complete" else { return nil }
            return (.info, "закончила ход" + (first(d["last-assistant-message"]?.string).map { ": \($0)" } ?? ""))
        }
        switch e.event {
        case "SessionStart":
            let src = d["source"]?.string ?? ""
            return (.info, src == "resume" ? "сессия продолжена" : src == "compact" ? "контекст сжат" : "сессия началась")
        case "UserPromptSubmit":
            return (.info, "получила задачу")
        case "PermissionRequest":
            let r = SessionReducer.request(from: d)
            let what = r.kind == .question ? "вопрос" : "разрешение \(r.tool ?? "")".trimmingCharacters(in: .whitespaces)
            return (.attention, "\(what): \(first(r.summary) ?? "")")
        case "Notification":
            let type = d["notification_type"]?.string ?? ""
            let msg = first(d["message"]?.string) ?? type
            if type == "permission_prompt" || type.contains("elicitation") { return (.attention, msg) }
            return type == "idle_prompt" ? nil : (.info, msg)
        case "Stop", "Interrupt":
            let m = first(d["last_assistant_message"]?.string)
            return (.info, (e.event == "Interrupt" ? "прервана" : "закончила ход") + (m.map { ": \($0)" } ?? ""))
        case "StopFailure":
            return (.problem, "ошибка: \(first(d["error"]?.string) ?? "?")")
        case "SessionEnd":
            return (.info, "закрыта" + (d["reason"]?.string.map { " (\($0))" } ?? ""))
        default:
            return nil
        }
    }

    private mutating func tool(_ key: SessionKey, ts: Double, name: String) {
        var list = entries[key] ?? []
        if var last = list.last, last.kind == .tools {
            last.toolCount += 1
            last.ts = ts
            if !last.tools.contains(name) { last.tools.append(name) }
            last.text = Self.toolsText(last.tools, count: last.toolCount)
            list[list.count - 1] = last
            entries[key] = list
            return
        }
        var e = HistoryEntry(id: nextId, ts: ts, kind: .tools, text: "")
        nextId += 1
        e.toolCount = 1; e.tools = [name]
        e.text = Self.toolsText(e.tools, count: 1)
        list.append(e)
        entries[key] = Array(list.suffix(Self.perSession))
    }

    static func toolsText(_ tools: [String], count: Int) -> String {
        let names = tools.prefix(4).joined(separator: ", ") + (tools.count > 4 ? "…" : "")
        return count == 1 ? "инструмент: \(names)" : "инструменты ×\(count): \(names)"
    }

    private mutating func append(_ key: SessionKey, ts: Double, kind: HistoryEntry.Kind, text: String) {
        var list = entries[key] ?? []
        list.append(HistoryEntry(id: nextId, ts: ts, kind: kind, text: text))
        nextId += 1
        entries[key] = Array(list.suffix(Self.perSession))
    }
}

/// Отрисовка экрана tmux для окна: строки без ANSI, серые/dim участки отдельно.
public struct ScreenLine: Equatable {
    public struct Run: Equatable {
        public var text: String
        public var dim: Bool
    }
    public var runs: [Run]
    public var plain: String { runs.map(\.text).joined() }
}

public enum ScreenText {
    /// Строки для показа. Подряд идущие пустые строки схлопываются в одну: у Claude под текстом
    /// часто пол-экрана пустоты, и без этого виден только низ панели.
    public static func lines(_ raw: [String]) -> [ScreenLine] {
        let parsed: [ScreenLine] = raw.map { line in
            let styled = ScreenClassifier.parseANSI(line)
            var runs: [ScreenLine.Run] = []
            for (ch, dim) in zip(styled.text, styled.dim) {
                if let last = runs.last, last.dim == dim { runs[runs.count - 1].text.append(ch) }
                else { runs.append(.init(text: String(ch), dim: dim)) }
            }
            return ScreenLine(runs: runs)
        }
        var out: [ScreenLine] = []
        for line in parsed {
            let blank = line.plain.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, let last = out.last, last.plain.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            out.append(line)
        }
        return out
    }
}

/// Фильтр списка в основном окне.
public enum SessionFilter: String, CaseIterable, Equatable {
    case waiting, running, all

    public func matches(_ s: Session) -> Bool {
        switch self {
        case .waiting: return s.status == .needsInput
        case .running: return s.status == .running
        case .all: return s.status != .ended
        }
    }
}
