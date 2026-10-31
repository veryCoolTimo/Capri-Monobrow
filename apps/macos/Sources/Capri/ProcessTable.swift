import AppKit
import Darwin
import CapriKit

/// Снимок своих процессов и окон для `TerminalLocator` — без разрешений: `sysctl` (только процессы своего
/// пользователя), аргументы — только у `ssh`, окна — `CGWindowList` без названий.
enum ProcessTable {
    /// Процессы своего пользователя: pid, ppid, имя, старт; у `ssh` — аргументы.
    static func snapshot() -> [TerminalLocator.Proc] {
        // По реальному uid: `/usr/bin/login` (Terminal, iTerm) работает с euid 0, но ruid — свой.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_RUID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // Процессы могут появиться между вызовами — запас.
        size += size / 4
        let stride = MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }
        return buf.prefix(size / stride).map { kp in
            let pid = kp.kp_proc.p_pid
            let name = withUnsafeBytes(of: kp.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let tv = kp.kp_proc.p_un.__p_starttime
            return TerminalLocator.Proc(pid: pid, ppid: kp.kp_eproc.e_ppid, name: name,
                                        start: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6,
                                        args: name == "ssh" ? arguments(pid) : [])
        }
    }

    /// Аргументы процесса (`KERN_PROCARGS2`).
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 1 << 20 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return TerminalLocator.parseProcArgs(Array(buf.prefix(size)))
    }

    /// Окна на экране спереди назад (без названий — разрешение на запись экрана не нужно).
    static func windows() -> [WindowInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return raw.compactMap(WindowInfo.from)
    }

    /// pid → bundle id запущенных приложений (вызывать на главном потоке).
    static func apps() -> [Int32: String] {
        var out: [Int32: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let b = app.bundleIdentifier { out[app.processIdentifier] = b }
        }
        return out
    }

    /// Найти окно терминала сессии: клиенты tmux (локально, ≤ 1 с) или ssh по алиасу → `TerminalLocator`.
    /// `screen` — экран notch (AppKit). Результат — на главной очереди; рамка окна — в координатах AppKit.
    static func locate(transport: HostSource.Transport, pane: String?, screen: NSScreen,
                       completion: @escaping (TerminalLocator.Location, CGRect?) -> Void) {
        let apps = apps()
        let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let f = screen.frame
        let cgScreen = CGRect(x: f.minX, y: primary - f.maxY, width: f.width, height: f.height)
        func finish(_ target: TerminalLocator.Target) {
            DispatchQueue.global(qos: .userInitiated).async {
                let loc = TerminalLocator.locate(target, procs: snapshot(), apps: apps, windows: windows(), screen: cgScreen)
                let rect = loc.window.map { SceneLayout.appKit($0, primaryHeight: primary) }
                DispatchQueue.main.async { completion(loc, rect) }
            }
        }
        switch transport {
        case .ssh(let host):
            finish(.ssh(host: host))
        case .local:
            guard let pane, pane.first == "%", pane.dropFirst().allSatisfy(\.isNumber),
                  TerminalOpener.localTmux.hasPrefix("/") else { return finish(.local(clients: [])) }
            HostCommand.run([TerminalOpener.localTmux, "list-clients", "-t", pane, "-F", "#{client_pid} #{client_activity}"],
                            timeout: 1) { out in
                finish(.local(clients: TerminalLocator.parseClients(out.stdout)))
            }
        }
    }
}
