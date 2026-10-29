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
            // Своё соединение: общий ControlMaster из ~/.ssh/config держал бы пайпы и мешал обрывам.
            return ["/usr/bin/ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none",
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
        let box = Collected()
        for (pipe, isOut) in [(out, true), (err, false)] {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { box.append(d, toOut: isOut) }
            }
        }
        func finish(status: Int32, timedOut: Bool, error: String? = nil) {
            guard let (o, e) = box.finish() else { return }
            for pipe in [out, err] { pipe.fileHandleForReading.readabilityHandler = nil }
            let output = Output(status: status, stdout: String(decoding: o, as: UTF8.self),
                                stderr: error ?? String(decoding: e, as: UTF8.self), timedOut: timedOut)
            DispatchQueue.main.async { completion(output) }
        }
        // Завершение — по выходу процесса (+ короткий добор вывода), а не по EOF пайпов: потомок
        // (например, мастер-соединение ssh) может держать их открытыми.
        p.terminationHandler = { proc in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                finish(status: proc.terminationStatus, timedOut: false)
            }
        }
        do {
            try p.run()
        } catch {
            finish(status: -1, timedOut: false, error: "\(error)")
            return
        }
        if let stdin {
            DispatchQueue.global(qos: .userInitiated).async {
                // Процесс мог уже выйти: запись в закрытый пайп — ошибка, а не SIGPIPE (он игнорируется в Capri).
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard !box.isFinished else { return }
            if p.isRunning { p.terminate() }
            finish(status: -1, timedOut: true)
        }
    }

    /// Вывод процесса и флаг завершения под замком: пишут обработчики пайпов, читает завершение.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var finished = false

        func append(_ d: Data, toOut: Bool) {
            lock.lock(); defer { lock.unlock() }
            if toOut { out.append(d) } else { err.append(d) }
        }

        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        /// Данные при первом вызове, nil — уже завершено.
        func finish() -> (Data, Data)? {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return nil }
            finished = true
            return (out, err)
        }
    }
}
