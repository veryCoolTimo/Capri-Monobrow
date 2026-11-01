import Foundation
import CoreGraphics

/// Где на Маке окно терминала сессии — без записи экрана (названий окон нет): по таблице процессов и списку окон.
/// Best effort: несколько окон одного терминала не различаем — берём верхнее.
public enum TerminalLocator {
    /// Процесс своего пользователя (`sysctl KERN_PROC_UID`; аргументы — только у `ssh`).
    public struct Proc: Equatable {
        public var pid: Int32
        public var ppid: Int32
        public var name: String
        /// Время старта (с 1970).
        public var start: Double
        public var args: [String]

        public init(pid: Int32, ppid: Int32, name: String, start: Double = 0, args: [String] = []) {
            self.pid = pid; self.ppid = ppid; self.name = name; self.start = start; self.args = args
        }
    }

    /// Чья сессия: локальная tmux (клиенты панели: pid и время активности) или по ssh (алиас хоста).
    public enum Target: Equatable {
        case local(clients: [Client])
        case ssh(host: String)
    }

    /// Клиент tmux (`#{client_pid} #{client_activity}`).
    public struct Client: Equatable {
        public var pid: Int32
        public var activity: Double
        public init(pid: Int32, activity: Double) { self.pid = pid; self.activity = activity }
    }

    public struct Location: Equatable {
        /// pid приложения-терминала (nil — не нашли).
        public var pid: Int32?
        /// Рамка окна (CG: от верхнего левого угла главного экрана); nil — угол экрана.
        public var window: CGRect?
        /// Как нашли: `tmux-client`, `ssh`, `any-terminal`, `corner` — для debug.log.
        public var path: String
    }

    /// Окно для сцены: обычное (слой 0), видимое, не крошечное, на экране notch (`screen` — CG).
    static func usable(_ w: WindowInfo, screen: CGRect) -> Bool {
        w.layer == 0 && w.alpha > 0 && w.bounds.width >= 200 && w.bounds.height >= 120 && screen.intersects(w.bounds)
            && screen.contains(CGPoint(x: w.bounds.midX, y: w.bounds.midY))
    }

    /// Терминал-предок процесса: вверх по ppid до pid приложения из `terminals` (не дальше 64 шагов).
    public static func terminalAncestor(of pid: Int32, procs: [Int32: Proc], apps: [Int32: String]) -> Int32? {
        var p = pid
        for _ in 0..<64 {
            if let bundle = apps[p], terminals.contains(bundle) { return p }
            guard let next = procs[p]?.ppid, next > 1, next != p else { return nil }
            p = next
        }
        return nil
    }

    /// Свои `ssh` к хосту `alias` (алиас — отдельным аргументом, как его запускает «Открыть»: `ssh -t -- <host>`),
    /// самые свежие сверху.
    public static func sshProcesses(to alias: String, in procs: [Proc]) -> [Proc] {
        procs.filter { p in
            (p.name == "ssh" || p.args.first.map { ($0 as NSString).lastPathComponent == "ssh" } == true)
                && p.args.dropFirst().contains(alias)
        }.sorted { $0.start > $1.start }
    }

    /// Терминалы — те же, что для «захвата».
    public static var terminals: Set<String> { SceneLayout.terminals }

    /// Поиск: процесс сессии → терминал-предок → его верхнее окно; иначе верхнее окно любого терминала; иначе угол.
    /// `windows` — спереди назад, `apps` — pid → bundle id запущенных приложений.
    public static func locate(_ target: Target, procs: [Proc], apps: [Int32: String], windows: [WindowInfo],
                              screen: CGRect) -> Location {
        let table = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let starts: [Int32]
        let via: String
        switch target {
        case .local(let clients):
            starts = clients.sorted { $0.activity > $1.activity }.map(\.pid)
            via = "tmux-client"
        case .ssh(let host):
            starts = sshProcesses(to: host, in: procs).map(\.pid)
            via = "ssh"
        }
        for pid in starts {
            guard let term = terminalAncestor(of: pid, procs: table, apps: apps) else { continue }
            if let w = windows.first(where: { $0.pid == term && usable($0, screen: screen) }) {
                return Location(pid: term, window: w.bounds, path: "\(via)→\(apps[term] ?? "?")")
            }
        }
        if let w = windows.first(where: { apps[$0.pid].map(terminals.contains) == true && usable($0, screen: screen) }) {
            return Location(pid: w.pid, window: w.bounds, path: "any-terminal→\(apps[w.pid] ?? "?")")
        }
        return Location(pid: nil, window: nil, path: "corner")
    }

    /// Разбор `tmux list-clients -F '#{client_pid} #{client_activity}'`.
    public static func parseClients(_ out: String) -> [Client] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 2, let pid = Int32(f[0]), pid > 1, let a = Double(f[1]) else { return nil }
            return Client(pid: pid, activity: a)
        }
    }

    /// Разбор буфера `KERN_PROCARGS2`: argc (Int32), путь программы, выравнивание нулями, затем argc строк.
    public static func parseProcArgs(_ data: [UInt8]) -> [String] {
        guard data.count > 4 else { return [] }
        let argc = Int(data[0]) | Int(data[1]) << 8 | Int(data[2]) << 16 | Int(data[3]) << 24
        guard argc > 0, argc < 4096 else { return [] }
        var i = 4
        while i < data.count, data[i] != 0 { i += 1 }        // путь программы
        while i < data.count, data[i] == 0 { i += 1 }        // выравнивание
        var args: [String] = []
        while args.count < argc, i < data.count {
            var j = i
            while j < data.count, data[j] != 0 { j += 1 }
            args.append(String(decoding: data[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
    }
}

// MARK: обратный поиск: что живёт под окном терминала (этап 3 присутствия)

extension TerminalLocator {
    /// Что под терминалом: локальный tmux-клиент, ssh к хосту, агент прямо в оболочке.
    public enum Underneath: Equatable {
        /// tmux-клиент; `session` — из `-t` (attach), иначе — по `tmux list-clients`.
        case tmux(pid: Int32, session: String?)
        /// ssh к алиасу; `session` — tmux-сессия из удалённой команды (`tmux attach -t X`), если есть.
        case ssh(pid: Int32, host: String, session: String?)
        /// claude/codex запущен прямо в оболочке (локально, без tmux).
        case agent(pid: Int32, agent: Agent)

        public var pid: Int32 {
            switch self {
            case .tmux(let p, _), .ssh(let p, _, _), .agent(let p, _): p
            }
        }
    }

    /// Находка под терминалом и когда её процесс стартовал (свежая — человек только что открыл/подключился).
    public struct Found: Equatable {
        public var what: Underneath
        public var start: Double
        public init(_ what: Underneath, start: Double) { self.what = what; self.start = start }
    }

    /// Потомки приложения-терминала `term` (вниз по ppid): tmux-клиенты, ssh, агенты. Внутрь найденного не спускаемся
    /// (ssh → tmux attach — это удалённая команда, не локальный клиент). Свежие сверху.
    public static func targets(underTerminal term: Int32, procs: [Proc]) -> [Found] {
        var children: [Int32: [Proc]] = [:]
        for p in procs where p.pid != p.ppid { children[p.ppid, default: []].append(p) }
        var out: [Found] = []
        var queue = children[term] ?? []
        var seen: Set<Int32> = [term]
        var steps = 0
        while !queue.isEmpty, steps < 4096 {
            steps += 1
            let p = queue.removeFirst()
            guard seen.insert(p.pid).inserted else { continue }
            if let what = classify(p) {
                out.append(Found(what, start: p.start))
                continue
            }
            queue += children[p.pid] ?? []
        }
        return out.sorted { $0.start > $1.start }
    }

    static func base(_ s: String) -> String { (s as NSString).lastPathComponent }

    /// Процесс — tmux-клиент, ssh или агент? (сервер tmux живёт под launchd — сюда не попадает).
    static func classify(_ p: Proc) -> Underneath? {
        let exe = p.args.first.map(base) ?? p.name
        switch p.name {
        case "ssh":
            guard let t = sshTarget(p.args) else { return nil }
            return .ssh(pid: p.pid, host: t.host, session: t.session)
        case "tmux":
            return .tmux(pid: p.pid, session: tmuxSession(Array(p.args.dropFirst())))
        case "claude":
            return .agent(pid: p.pid, agent: .claude)
        case "codex":
            return .agent(pid: p.pid, agent: .codex)
        case "node":
            // `node …/bin/codex …` или `node …/claude …`.
            if let script = p.args.dropFirst().first(where: { !$0.hasPrefix("-") }).map(base) {
                if script == "codex" || script.hasPrefix("codex.") { return .agent(pid: p.pid, agent: .codex) }
                if script == "claude" || script == "cli.js" && p.args.joined(separator: " ").contains("claude-code") {
                    return .agent(pid: p.pid, agent: .claude)
                }
            }
            return nil
        default:
            if exe == "claude" { return .agent(pid: p.pid, agent: .claude) }
            return nil
        }
    }

    /// Опции ssh со значением (`-p 22`, `-i key` …): значение — не хост.
    static let sshValueFlags = Set("BbcDEeFIiJLlmOoPpQRSWw".map { $0 })

    /// Хост (алиас) и tmux-сессия из удалённой команды: `ssh [-опции] [--] host [команда…]`. nil — не разобрали.
    public static func sshTarget(_ args: [String]) -> (host: String, session: String?)? {
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--" { i += 1; break }
            guard a.hasPrefix("-"), a.count > 1 else { break }
            // `-p22` — значение слитно; `-p 22` — следующим аргументом; `-tt`, `-A` — без значения.
            if let last = a.last, a.count == 2, sshValueFlags.contains(last) { i += 2 } else { i += 1 }
        }
        guard i < args.count else { return nil }
        var host = args[i]
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        guard !host.isEmpty, !host.hasPrefix("-") else { return nil }
        // Удалённая команда может прийти одной строкой («tmux attach -t votek») или словами.
        let words = args[(i + 1)...].flatMap { $0.split(separator: " ").map(String.init) }
        var session: String?
        if let k = words.firstIndex(where: { base($0) == "tmux" }) { session = tmuxSession(Array(words[(k + 1)...])) }
        return (host, session)
    }

    /// Имя сессии (или `%N` панели) из аргументов tmux: команда `attach|a|attach-session|new -A` где угодно в цепочке
    /// (`select-window -t %5 \; attach-session -t %5` — так открывает «Открыть»), после неё `-t X` / `-s X`.
    /// nil — не указано (или это не подключение).
    public static func tmuxSession(_ args: [String]) -> String? {
        let attach: Set<String> = ["attach", "a", "at", "attach-session", "new", "new-session"]
        guard let k = args.firstIndex(where: { attach.contains($0) }) else { return nil }
        var i = k + 1
        while i < args.count {
            let a = args[i]
            if a == ";" || a == "\\;" { break }
            if a == "-t" || a == "-s", i + 1 < args.count { return target(args[i + 1]) }
            if a.hasPrefix("-t"), a.count > 2 { return target(String(a.dropFirst(2))) }
            i += 1
        }
        return nil
    }

    /// `name:1.0` → `name`; `%5` — как есть.
    static func target(_ v: String) -> String? {
        let s = v.hasPrefix("%") ? v : v.split(separator: ":").first.map(String.init) ?? v
        return s.isEmpty ? nil : s
    }
}
