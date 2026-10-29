import Foundation

/// Как достучаться до capri-hook одного хоста: локально или по ssh.
/// Один источник даёт и поток событий (`stream`), и разовые команды (`send`).
public struct HostSource: Equatable {
    public enum Transport: Equatable {
        case local
        case ssh(String)
    }

    public var name: String
    public var transport: Transport
    /// Как вызвать capri-hook на хосте (shell-строка, `~` и `$HOME` раскрывает оболочка хоста).
    public var hook: String
    /// Дополнительные аргументы `stream`, например `--only-sessions capri-test-`.
    public var streamArgs: [String]

    public static let defaultLocalHook = "/usr/bin/python3 \"$HOME/.capri/bin/capri-hook\""
    public static let defaultRemoteHook = "python3 ~/.capri/bin/capri-hook"

    public init(name: String, transport: Transport, hook: String, streamArgs: [String] = []) {
        self.name = name; self.transport = transport; self.hook = hook; self.streamArgs = streamArgs
    }

    public static func local(name: String = "local", hook: String = defaultLocalHook, streamArgs: [String] = []) -> HostSource {
        HostSource(name: name, transport: .local, hook: hook, streamArgs: streamArgs)
    }

    public static func ssh(_ host: String, name: String? = nil, hook: String = defaultRemoteHook,
                           streamArgs: [String] = []) -> HostSource {
        HostSource(name: name ?? host, transport: .ssh(host), hook: hook, streamArgs: streamArgs)
    }

    /// argv процесса на Маке, выполняющего `capri-hook <args>` на хосте. Аргументы экранируются.
    public func command(_ args: [String]) -> [String] {
        let line = ([hook] + args.map(shellQuote)).joined(separator: " ")
        switch transport {
        case .local:
            // `exec env …` — чтобы работали префиксы `VAR=… cmd` и процесс-потомок не пережил остановку.
            return ["/bin/sh", "-c", "exec /usr/bin/env " + line]
        case .ssh(let host):
            return ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "--", host, line]
        }
    }
}

/// Одинарные кавычки для sh: безопасно для любого текста.
public func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./%=:@,+".contains($0) }), s.allSatisfy(\.isASCII) {
        return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Разовая команда на хосте: stdin → процесс → stdout. Завершение — на главной очереди.
public enum HostCommand {
    public struct Output: Equatable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
    }

    public static func run(_ argv: [String], stdin: Data? = nil, timeout: TimeInterval = 15,
                           completion: @escaping (Output) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input
        // Чтение stdout/stderr, запись stdin и ожидание — на разных потоках, иначе взаимная блокировка.
        let queue = DispatchQueue.global(qos: .userInitiated)
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            queue.async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = d } else { errData = d }
                group.leave()
            }
        }
        var timedOut = false
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        do {
            try p.run()
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            group.notify(queue: .main) { completion(Output(status: -1, stdout: "", stderr: "\(error)", timedOut: false)) }
            return
        }
        if let stdin {
            queue.async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        queue.async {
            p.waitUntilExit()
            killer.cancel()
            group.notify(queue: .main) {
                completion(Output(status: p.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                                  stderr: String(decoding: errData, as: UTF8.self), timedOut: timedOut))
            }
        }
    }
}
