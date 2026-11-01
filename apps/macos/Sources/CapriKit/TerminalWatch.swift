import Foundation

/// Терминал с Claude: какие сессии Capri живут под окном терминала и открыл ли его человек только что.
/// Чистая логика: процессы, клиенты tmux и сессии — входом.
public enum TerminalWatch {
    /// Сессия под терминалом и чем найдена.
    public struct Match: Equatable {
        public var key: SessionKey
        public var via: TerminalLocator.Underneath
        /// Старт процесса пути (ssh, tmux-клиент, агент).
        public var start: Double
        public init(key: SessionKey, via: TerminalLocator.Underneath, start: Double) { self.key = key; self.via = via; self.start = start }

        /// Отпечаток «открытия»: тот же процесс второй раз поводом не станет.
        public var opening: String { "\(via.pid)@\(Int(start))" }
    }

    /// Свежим считается путь, чей процесс стартовал не раньше стольких секунд назад: «открыл терминал / подключился /
    /// запустил claude» — а не переключился на старое окно.
    public static let freshFor = 180.0

    /// Сессии Capri под терминалом. `clients` — pid tmux-клиента → имя сессии (`tmux list-clients`), `cwds` — pid
    /// агента → его рабочая папка, `localHost` — имя этого Мака в сессиях. Закрытые сессии не берём.
    public static func match(_ found: [TerminalLocator.Found], sessions: [Session], clients: [Int32: String] = [:],
                             cwds: [Int32: String] = [:], localHost: String = "local") -> [Match] {
        var out: [Match] = []
        var taken: Set<SessionKey> = []
        let live = sessions.filter { $0.status != .ended }
        for f in found {
            let hits: [Session]
            switch f.what {
            case .tmux(let pid, let name):
                guard let name = name ?? clients[pid] else { continue }
                hits = live.filter { $0.key.host == localHost && on($0, name) }
            case .ssh(_, let host, let name):
                // Голый `ssh host` — не «открыл терминал с Claude»: мог зайти за чем угодно. Только с tmux-сессией.
                guard let name else { continue }
                hits = live.filter { s in s.key.host == host && on(s, name) }
            case .agent(let pid, let agent):
                guard let cwd = cwds[pid] else { continue }
                hits = live.filter { $0.key.host == localHost && $0.key.agent == agent && $0.tmux == nil && $0.cwd == cwd }
            }
            for s in hits where taken.insert(s.key).inserted {
                out.append(Match(key: s.key, via: f.what, start: f.start))
            }
        }
        return out
    }

    /// Сессия в tmux-сессии `name` (или на панели `%N`).
    static func on(_ s: Session, _ name: String) -> Bool {
        name.hasPrefix("%") ? s.tmux?.pane == name : s.tmux?.session == name
    }

    /// Самое свежее «открытие» среди находок, если оно моложе `freshFor` и ещё не было поводом (`used`).
    public static func opening(_ m: [Match], now: Double, used: Set<String> = []) -> Match? {
        m.filter { now - $0.start <= freshFor && now >= $0.start - 5 && !used.contains($0.opening) }.max { $0.start < $1.start }
    }

    /// За какой сессией смотреть: работающая, самая свежая по пути; иначе первая.
    public static func primary(_ m: [Match], sessions: [Session]) -> Match? {
        let status = Dictionary(sessions.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a })
        return m.filter { status[$0.key] == .running }.max { $0.start < $1.start } ?? m.first
    }
}
