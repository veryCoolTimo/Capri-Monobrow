import AppKit
import CapriKit

/// «Открыть»: Terminal с `tmux attach` на панель сессии — локально или по ssh.
enum TerminalOpener {
    static let localTmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "tmux"

    /// Команда для zsh. Панель — `%N` (проверено), имя хоста экранировано.
    static func command(pane: String, transport: HostSource.Transport) -> String? {
        guard pane.count > 1, pane.first == "%", pane.dropFirst().allSatisfy(\.isNumber) else { return nil }
        // select-window/select-pane — чтобы попасть сразу в окно сессии, attach по %N находит её сессию.
        let tmuxArgs = "select-window -t \(pane) \\; select-pane -t \(pane) \\; attach-session -t \(pane)"
        switch transport {
        case .local:
            return "exec \(shellQuote(localTmux)) \(tmuxArgs)"
        case .ssh(let host):
            return "exec /usr/bin/ssh -t -- \(shellQuote(host)) \(shellQuote("tmux " + tmuxArgs))"
        }
    }

    @discardableResult
    static func open(pane: String, transport: HostSource.Transport) -> Bool {
        guard let cmd = command(pane: pane, transport: transport) else { return false }
        CapriPaths.ensureDir()
        let dir = CapriPaths.dir.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("open-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh\nrm -f \"$0\"\n\(cmd)\n"
        guard FileManager.default.createFile(atPath: file.path, contents: Data(script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else { return false }
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
