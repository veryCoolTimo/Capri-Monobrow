import AppKit
import AVFoundation
import CapriKit

/// Хелпер `capri-asr` (Contents/MacOS): отдельный процесс с моделью речи. Запускается при первой надобности
/// (прогрев — первое раскрытие notch, нажатие ⌃⌥Space), сам выходит после 5 минут простоя. Пишем в него на своей
/// очереди (пока модель грузится, pipe может быть полон — главный поток не ждёт); события — на главном.
final class AsrHelper {
    enum State: Equatable { case off, loading, ready, failed(String) }

    private(set) var state: State = .off
    var onEvent: ((AsrEvent) -> Void)?
    /// Процесс завершился (упал, вышел по простою); второе — это был простой.
    var onExit: ((Bool) -> Void)?
    var log: ((String) -> Void)?

    private var process: Process?
    /// Пишут с очереди микрофона, обнуляют на главной — под замком.
    private var _input: FileHandle?
    private let inputLock = NSLock()
    private var input: FileHandle? {
        get { inputLock.lock(); defer { inputLock.unlock() }; return _input }
        set { inputLock.lock(); _input = newValue; inputLock.unlock() }
    }
    private let writes = DispatchQueue(label: "capri.asr.write", qos: .userInitiated)
    private var idleExit = false

    /// Где лежит хелпер: в бандле рядом с Capri.
    static var binary: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/capri-asr")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    var running: Bool { process?.isRunning == true }

    /// Запустить, если не запущен. false — нечего запускать (нет хелпера или модели).
    @discardableResult
    func start(model: String) -> Bool {
        if running { return true }
        guard let bin = Self.binary else { state = .failed("нет capri-asr в сборке"); return false }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["--model", model]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        idleExit = false
        // Свой разборщик строк у каждого процесса: хвост старого не склеится с первой строкой нового.
        let splitter = SplitterBox()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, weak p] h in
            let data = h.availableData
            DispatchQueue.main.async {
                guard let self else { return }
                if data.isEmpty { h.readabilityHandler = nil; return }
                guard let p, self.process === p else { return }
                for line in splitter.value.feed(data) {
                    guard let e = AsrEvent.parse(line) else { continue }
                    switch e {
                    case .ready(let b, let ms): self.state = .ready; self.log?("asr ready \(b) \(ms) ms")
                    case .idle: self.idleExit = true
                    case .error(let m) where self.state == .loading: self.state = .failed(m)
                    default: break
                    }
                    self.onEvent?(e)
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.log?("asr exit \(proc.terminationStatus)\(self.idleExit ? " (простой)" : "")")
                self.process = nil
                self.input = nil
                if case .failed = self.state {} else { self.state = .off }
                self.onExit?(self.idleExit)
            }
        }
        do { try p.run() } catch {
            state = .failed("capri-asr не запустился")
            return false
        }
        process = p
        input = inPipe.fileHandleForWriting
        state = .loading
        log?("asr start pid=\(p.processIdentifier)")
        return true
    }

    func send(_ cmd: AsrCommand) {
        guard let h = input else { return }
        let data = cmd.encoded
        // SIGPIPE игнорируется (AppDelegate): умерший хелпер — ошибка записи, не падение Capri.
        writes.async { try? h.write(contentsOf: data) }
    }

    func stop() {
        send(.quit)
        let p = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if p?.isRunning == true { p?.terminate() } }
    }
}

/// Разборщик строк одного процесса хелпера (только на главной очереди).
private final class SplitterBox: @unchecked Sendable { var value = LineSplitter() }

/// Микрофон на время удержания клавиши: AVAudioEngine → 16 кГц mono Float32 кусками по ~100 мс.
/// Движок создаётся на каждое нажатие (наушники могли смениться) и останавливается сразу при отпускании —
/// оранжевая точка в строке меню горит, только пока держат клавишу.
final class MicCapture {
    /// Куски звука (на очереди `queue`) и громкость 0…1.
    var onAudio: (([Float], Double) -> Void)?
    let queue = DispatchQueue(label: "capri.mic", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Первый запрос разрешения — только по действию человека (удержание ⌃⌥Space).
    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    var running: Bool { engine?.isRunning == true }

    /// nil — запустилось; иначе почему нет.
    func start() -> String? {
        guard engine == nil else { return nil }
        guard Self.permission == .authorized else { return "нет доступа к микрофону" }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return "нет микрофона" }
        guard let conv = AVAudioConverter(from: format, to: target) else { return "микрофон: формат" }
        let target = self.target
        let ratio = target.sampleRate / format.sampleRate
        // Конвертер — свой у этого движка, захвачен замыканием (не читаем поле из аудиопотока, пока `stop()` его меняет).
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] buf, _ in
            guard let self else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
            var fed = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
            let pcm = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            var sum: Float = 0
            for v in pcm { sum += v * v }
            let rms = (sum / Float(max(1, pcm.count))).squareRoot()
            // ~−50 дБ — тишина, ~−10 дБ — громко.
            let db = 20 * log10(max(1e-6, Double(rms)))
            let level = max(0, min(1, (db + 50) / 40))
            self.queue.async { self.onAudio?(pcm, level) }
        }
        e.prepare()
        do { try e.start() } catch {
            input.removeTap(onBus: 0)
            return "микрофон не включился"
        }
        engine = e
        return nil
    }

    func stop() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
    }
}

/// `osascript` для Заметок и Напоминаний — в фоне (первый раз macOS спрашивает «Автоматизацию» и держит вызов).
protocol AutomationRunner: AnyObject {
    var name: String { get }
    /// Итог: nil — сделано, иначе `MusicScript.failure`-вид ошибки («denied», «consent», «error»).
    func run(_ script: String, completion: @escaping (String?) -> Void)
}

final class OsaScriptRunner: AutomationRunner {
    let name = "osascript"
    private let queue = DispatchQueue(label: "capri.automation", qos: .userInitiated)

    func run(_ script: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = MusicScript.arguments(script)
            let err = Pipe()
            p.standardOutput = FileHandle.nullDevice
            p.standardError = err
            var result: String?
            do {
                try p.run()
                // Первый раз macOS ждёт ответа человека на запрос «Автоматизации».
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
                let e = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                if p.terminationStatus != 0 { result = MusicScript.failure(String(decoding: e, as: UTF8.self)) }
            } catch {
                result = "error"
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// В отладке (`--debug-control`): скрипт в журнал (только что за приложение и сколько знаков), ничего не запускаем.
final class FakeAutomationRunner: AutomationRunner {
    let name = "fake"
    var log: ((String) -> Void)?
    private(set) var last: String?

    func run(_ script: String, completion: @escaping (String?) -> Void) {
        last = script
        let app = script.contains(AppleScripts.notesBundle) ? "notes" : script.contains(AppleScripts.remindersBundle) ? "reminders" : "?"
        log?("fake automation \(app) (\(script.count) зн.\(script.contains("due date") ? ", со сроком" : ""))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completion(nil) }
    }
}
