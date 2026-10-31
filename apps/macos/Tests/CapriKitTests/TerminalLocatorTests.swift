import XCTest
import CoreGraphics
@testable import CapriKit

/// Окно терминала сессии без названий окон: процесс → терминал-предок → верхнее окно.
final class TerminalLocatorTests: XCTestCase {
    typealias P = TerminalLocator.Proc
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    // Terminal (100), iTerm2 (200), Capri (300), Finder (400).
    let apps: [Int32: String] = [100: "com.apple.Terminal", 200: "com.googlecode.iterm2", 300: "dev.capri", 400: "com.apple.finder"]

    var procs: [P] {
        [
            P(pid: 100, ppid: 1, name: "Terminal"),
            P(pid: 200, ppid: 1, name: "iTerm2"),
            P(pid: 300, ppid: 1, name: "Capri"),
            // Terminal: login → zsh → tmux-клиент (1010) и ssh к devbox (1020, свежее).
            P(pid: 1001, ppid: 100, name: "login"),
            P(pid: 1002, ppid: 1001, name: "zsh"),
            P(pid: 1010, ppid: 1002, name: "tmux"),
            P(pid: 1003, ppid: 1001, name: "zsh"),
            P(pid: 1020, ppid: 1003, name: "ssh", start: 500, args: ["/usr/bin/ssh", "-t", "--", "devbox", "tmux attach"]),
            // iTerm2: zsh → tmux-клиент (2010) и старый ssh к devbox (2020).
            P(pid: 2001, ppid: 200, name: "zsh"),
            P(pid: 2010, ppid: 2001, name: "tmux"),
            P(pid: 2020, ppid: 2001, name: "ssh", start: 100, args: ["ssh", "devbox"]),
            // Сборщик Capri: ssh к devbox — потомок Capri, не терминала (свежий, но не подходит).
            P(pid: 3001, ppid: 300, name: "ssh", start: 900, args: ["/usr/bin/ssh", "-T", "devbox", "capri-hook", "stream"]),
            // ssh к prodbox.
            P(pid: 2030, ppid: 2001, name: "ssh", start: 50, args: ["ssh", "prodbox"]),
        ]
    }

    /// Спереди назад: Finder, iTerm2 (два окна), Terminal.
    let windows = [
        WindowInfo(pid: 400, layer: 0, bounds: CGRect(x: 10, y: 40, width: 600, height: 400)),
        WindowInfo(pid: 200, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1512, height: 25)),       // полоска — мала по высоте
        WindowInfo(pid: 200, layer: 0, bounds: CGRect(x: 300, y: 200, width: 800, height: 500)),
        WindowInfo(pid: 200, layer: 0, bounds: CGRect(x: 320, y: 220, width: 800, height: 500)),
        WindowInfo(pid: 100, layer: 0, bounds: CGRect(x: 50, y: 300, width: 700, height: 450)),
        WindowInfo(pid: 100, layer: 3, bounds: CGRect(x: 0, y: 0, width: 300, height: 300)),
    ]

    func locate(_ t: TerminalLocator.Target, windows: [WindowInfo]? = nil, apps: [Int32: String]? = nil) -> TerminalLocator.Location {
        TerminalLocator.locate(t, procs: procs, apps: apps ?? self.apps, windows: windows ?? self.windows, screen: screen)
    }

    func testLocalTmuxClientMostRecent() {
        // Самый свежий клиент — в Terminal.
        let l = locate(.local(clients: [.init(pid: 2010, activity: 10), .init(pid: 1010, activity: 20)]))
        XCTAssertEqual(l.pid, 100)
        XCTAssertEqual(l.window, CGRect(x: 50, y: 300, width: 700, height: 450))
        XCTAssertEqual(l.path, "tmux-client→com.apple.Terminal")
        // Свежее — в iTerm2: его верхнее (по z) обычное окно.
        let i = locate(.local(clients: [.init(pid: 2010, activity: 30), .init(pid: 1010, activity: 20)]))
        XCTAssertEqual(i.pid, 200)
        XCTAssertEqual(i.window, CGRect(x: 300, y: 200, width: 800, height: 500))
    }

    func testSSHByAliasSkipsCollector() {
        // Сборщик Capri свежее всех, но его предок — Capri; берём самый свежий ssh из терминала.
        let l = locate(.ssh(host: "devbox"))
        XCTAssertEqual(l.pid, 100)
        XCTAssertEqual(l.path, "ssh→com.apple.Terminal")
        XCTAssertEqual(locate(.ssh(host: "prodbox")).pid, 200)
        XCTAssertEqual(TerminalLocator.sshProcesses(to: "devbox", in: procs).map(\.pid), [3001, 1020, 2020])
        // Алиас — отдельный аргумент, не подстрока.
        XCTAssertTrue(TerminalLocator.sshProcesses(to: "timo", in: procs).isEmpty)
    }

    func testFallbacks() {
        // Клиента нет (сессия не открыта) — верхнее окно любого терминала.
        let any = locate(.local(clients: []))
        XCTAssertEqual(any.pid, 200)
        XCTAssertEqual(any.path, "any-terminal→com.googlecode.iterm2")
        // У терминала самого свежего ssh нет окна на этом экране — следующий ssh к тому же хосту (в iTerm2).
        let noWin = locate(.ssh(host: "devbox"), windows: windows.filter { $0.pid != 100 })
        XCTAssertEqual(noWin.pid, 200)
        XCTAssertEqual(noWin.path, "ssh→com.googlecode.iterm2")
        // Ни у одного — любой терминал.
        let other = locate(.ssh(host: "prodbox"), windows: windows.filter { $0.pid != 200 })
        XCTAssertEqual(other.pid, 100)
        XCTAssertTrue(other.path.hasPrefix("any-terminal"))
        // Терминалов нет — угол.
        let none = locate(.ssh(host: "devbox"), windows: [windows[0]])
        XCTAssertNil(none.window)
        XCTAssertEqual(none.path, "corner")
        // Окно на другом экране не берём.
        let off = locate(.local(clients: [.init(pid: 1010, activity: 1)]),
                         windows: [WindowInfo(pid: 100, layer: 0, bounds: CGRect(x: 2000, y: 100, width: 700, height: 400))])
        XCTAssertEqual(off.path, "corner")
    }

    func testAncestorLoopIsBounded() {
        let loop: [Int32: P] = [5: P(pid: 5, ppid: 6, name: "a"), 6: P(pid: 6, ppid: 5, name: "b")]
        XCTAssertNil(TerminalLocator.terminalAncestor(of: 5, procs: loop, apps: apps))
    }

    func testParsers() {
        let c = TerminalLocator.parseClients("1010 1730000000\n2010 1730000100\njunk\n0 5\n")
        XCTAssertEqual(c, [.init(pid: 1010, activity: 1730000000), .init(pid: 2010, activity: 1730000100)])
        // KERN_PROCARGS2: argc=3, путь, нули, аргументы, потом окружение.
        var buf: [UInt8] = [3, 0, 0, 0]
        buf += Array("/usr/bin/ssh".utf8) + [0, 0, 0, 0]
        for a in ["ssh", "-t", "devbox", "HOME=/Users/x"] { buf += Array(a.utf8) + [0] }
        XCTAssertEqual(TerminalLocator.parseProcArgs(buf), ["ssh", "-t", "devbox"])
        XCTAssertEqual(TerminalLocator.parseProcArgs([1, 0]), [])
        XCTAssertEqual(TerminalLocator.parseProcArgs([255, 255, 255, 127, 0]), [])
    }
}
