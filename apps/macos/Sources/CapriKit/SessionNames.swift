import Foundation

/// Как называть сессию в интерфейсе. У Тимофея несколько tmux-сессий в одной папке (`votek`, `votek2`,
/// `votek3`), поэтому имя папки их не различает — заголовок берём из имени tmux-сессии.
public struct SessionName: Equatable {
    /// Имя tmux-сессии целиком, без tmux — проект по папке.
    public var title: String
    /// Уточнение: проект, если он не совпадает с заголовком, и окно:панель, если в одной tmux-сессии
    /// несколько сессий агентов.
    public var detail: String?

    public init(title: String, detail: String? = nil) { self.title = title; self.detail = detail }

    /// «votek2 · votek» — для мест в одну строку.
    public var full: String { detail.map { "\(title) · \($0)" } ?? title }
}

extension Session {
    /// Заголовок без учёта соседей (для промптов и уведомлений): имя tmux-сессии или проект.
    public var title: String {
        if let t = tmux?.session?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        return project
    }
}

public enum SessionNames {
    public static func names(_ sessions: [Session]) -> [SessionKey: SessionName] {
        // Сколько сессий агентов в каждой tmux-сессии хоста.
        var shared: [String: Int] = [:]
        for s in sessions { if let t = s.tmux?.session { shared["\(s.key.host)\u{0}\(t)", default: 0] += 1 } }
        var out: [SessionKey: SessionName] = [:]
        for s in sessions {
            var parts: [String] = []
            if s.project.caseInsensitiveCompare(s.title) != .orderedSame { parts.append(s.project) }
            if let t = s.tmux, let name = t.session, shared["\(s.key.host)\u{0}\(name)", default: 0] > 1 {
                parts.append(t.window.map { "\($0):\(t.pane)" } ?? t.pane)
            }
            out[s.key] = SessionName(title: s.title, detail: parts.isEmpty ? nil : parts.joined(separator: " · "))
        }
        return out
    }
}

/// Порядок списка сессий, который не прыгает: группа статуса, внутри — стабильный ключ.
/// Свежесть событий на порядок не влияет — иначе работающие сессии меняются местами на каждом хуке.
public enum SessionOrder {
    public enum Group: Int, Comparable {
        case waiting, running, other
        public static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
    }

    public static func group(_ s: Session) -> Group {
        switch s.status {
        case .needsInput: return .waiting
        case .running: return .running
        default: return .other
        }
    }

    /// `hosts` — порядок хостов (как в настройках); неизвестные — в конце по имени.
    public static func sorted(_ sessions: [Session], hosts: [String]) -> [Session] {
        func hostRank(_ h: String) -> Int { hosts.firstIndex(of: h) ?? hosts.count }
        return sessions.sorted { a, b in
            let ga = group(a), gb = group(b)
            if ga != gb { return ga < gb }
            // Ждущие — сверху самые старые: время начала ожидания не меняется, пока сессия ждёт.
            if ga == .waiting, a.statusSince != b.statusSince { return a.statusSince < b.statusSince }
            return stableKey(a, hostRank(a.key.host)).lexicographicallyPrecedes(stableKey(b, hostRank(b.key.host)))
        }
    }

    static func stableKey(_ s: Session, _ hostRank: Int) -> [String] {
        let window = s.tmux?.window.flatMap { Int($0) } ?? 0
        let pane = s.tmux.flatMap { Int($0.pane.dropFirst()) } ?? 0
        return [String(format: "%04d", hostRank), s.key.host, s.title.lowercased(),
                String(format: "%06d", window), String(format: "%08d", pane), s.key.agent.rawValue, s.key.id]
    }
}
