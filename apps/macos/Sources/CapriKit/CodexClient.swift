import Foundation

public enum CodexError: Error, Equatable {
    case notRunning
    case timeout
    case server(String)
    case exited(String)
}

/// Процесс `codex app-server` и JSON-RPC поверх его stdin/stdout. Всё состояние — на главном потоке:
/// чтение pipe переносится на main, обратные вызовы тоже приходят на main.
public final class CodexClient {
    public typealias Completion = (Result<JSONValue?, CodexError>) -> Void

    /// Уведомление сервера (метод, параметры).
    public var onNotification: ((String, JSONValue) -> Void)?
    /// Процесс завершился (последние строки stderr для диагностики).
    public var onExit: ((String) -> Void)?

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: Completion] = [:]
    private var nextId = 0
    private var buffer = Data()
    private var stderrTail = ""

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    public func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async {
                guard let self, !data.isEmpty else { return }
                self.stderrTail = String((self.stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
            }
        }
        p.terminationHandler = { [weak self] ended in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.exited(ended) }
        }
        try p.run()
        process = p
        input = stdin.fileHandleForWriting
    }

    public func stop() {
        guard let p = process else { return }
        process = nil
        try? input?.close()
        input = nil
        if p.isRunning { p.terminate() }
        failAll(.exited("остановлен"))
    }

    /// Запрос с ответом. Таймаут снимает ожидание (сам запрос на сервере не отменяется).
    public func call(_ method: String, _ params: JSONValue? = nil, timeout: Double = 30, completion: @escaping Completion) {
        guard let input, isRunning else { completion(.failure(.notRunning)); return }
        nextId += 1
        let id = nextId
        pending[id] = completion
        write(input, CodexMessage.encode(method: method, params: params, id: id))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let c = self.pending.removeValue(forKey: id) else { return }
            c(.failure(.timeout))
        }
    }

    public func notify(_ method: String, _ params: JSONValue? = nil) {
        guard let input, isRunning else { return }
        write(input, CodexMessage.encode(method: method, params: params, id: nil))
    }

    private func write(_ h: FileHandle, _ data: Data) {
        do { try h.write(contentsOf: data) } catch { /* процесс вышел — разберёт terminationHandler */ }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let msg = CodexMessage.decode(line) else { continue }
            handle(msg)
        }
        // Одна строка не бывает больше нескольких МБ — защита от бесконечного буфера.
        if buffer.count > 8 << 20 { buffer.removeAll() }
    }

    private func handle(_ msg: CodexMessage) {
        switch msg {
        case let .response(id, result, error):
            guard let c = pending.removeValue(forKey: id) else { return }
            if let error { c(.failure(.server(error))) } else { c(.success(result)) }
        case let .notification(method, params):
            onNotification?(method, params)
        case let .request(id, method, _):
            // Треды Capri только читают (sandbox read-only, approval never) — любые запросы одобрения отклоняем.
            guard let input else { return }
            if method.hasSuffix("requestApproval") {
                write(input, CodexMessage.encodeResponse(id: id, result: .object(["decision": .string("decline")])))
            } else if method == "execCommandApproval" || method == "applyPatchApproval" {
                write(input, CodexMessage.encodeResponse(id: id, result: .object(["decision": .string("denied")])))
            } else {
                // Незнакомый запрос — ошибка, а не пустой ответ (пустой могут счесть согласием).
                write(input, CodexMessage.encodeError(id: id, code: -32601, message: "Capri не поддерживает \(method)"))
            }
        }
    }

    /// Неожиданный выход текущего процесса. Остановленный через `stop()` или уже заменённый — не сообщаем.
    private func exited(_ ended: Process) {
        guard ended === process else { return }
        let tail = stderrTail.split(separator: "\n").suffix(3).joined(separator: " · ")
        process = nil
        input = nil
        buffer.removeAll()
        failAll(.exited(tail))
        onExit?(tail)
    }

    private func failAll(_ e: CodexError) {
        let all = pending
        pending.removeAll()
        for (_, c) in all { c(.failure(e)) }
    }
}
