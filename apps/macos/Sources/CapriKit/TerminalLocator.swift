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
