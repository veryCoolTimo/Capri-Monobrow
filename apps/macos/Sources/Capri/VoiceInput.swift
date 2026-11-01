import AppKit
import AVFoundation
import CoreAudio
import CoreMedia
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

/// Входы звука (CoreAudio) для выбора в Настройках → Голос: список и системный по умолчанию, обновляются сами
/// (подключили наушники, сменили вход в macOS). Разрешения не нужны — только имена и типы, не звук.
final class MicDevices: ObservableObject {
    @Published private(set) var devices: [MicDevice] = []
    @Published private(set) var defaultUID: String?
    private var listening = false

    init() { refresh() }

    /// Слушать изменения (при первом показе настроек или нажатии): блоки на главной очереди.
    func watch() {
        guard !listening else { return }
        listening = true
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for sel in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(sys, &a, .main) { [weak self] _, _ in self?.refresh() }
        }
    }

    func refresh() {
        let list = Self.inputs()
        let def = Self.defaultInput()
        if list != devices { devices = list }
        if def != defaultUID { defaultUID = def }
    }

    static func inputs() -> [MicDevice] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputStreams(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var t = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var code: UInt32 = 0
            var sz = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &t, 0, nil, &sz, &code)
            return MicDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, transport: MicDevice.transport(code: code))
        }
    }

    static func defaultInput() -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    private static func inputStreams(_ id: AudioDeviceID) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        let s = v as String
        return s.isEmpty ? nil : s
    }
}

/// Микрофон на время удержания клавиши: выбранный вход (`MicChoice`) через AVCaptureSession — системный вход
/// по умолчанию не меняется, AirPods не трогаем, если выбран встроенный. Звук в родном формате входа →
/// `PcmResampler` → 16 кГц mono Float32 кусками, как пришли (~10–100 мс). Сессия создаётся на каждое удержание
/// и останавливается сразу при отпускании — оранжевая точка горит, только пока держат клавишу. Запуск — на своей
/// очереди (Bluetooth включается до секунды — главный поток не ждёт).
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Что открыто и сколько пришло — для журнала (`voice mic …`).
    struct Stats {
        var device = ""
        var format = ""
        var seconds = 0.0
        var peak = 0.0
        var formatChanges = 0
    }

    /// Куски звука (на очереди `queue`) и громкость 0…1.
    var onAudio: (([Float], Double) -> Void)?
    /// Вход пропал посреди фразы (выдернули, наушники в футляр) или сессия упала — на главной.
    var onLost: ((String) -> Void)?
    let queue = DispatchQueue(label: "capri.mic", qos: .userInitiated)

    /// Только главная очередь.
    private(set) var running = false
    /// Номер открытия (главная очередь): поздний ответ прошлого `start` и второе уведомление о той же потере
    /// не трогают текущую сессию.
    private var generation = 0
    private var lostHandled = -1
    /// Только очередь `queue`.
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var resampler = PcmResampler()
    private var stats = Stats()
    private var observers: [NSObjectProtocol] = []
    /// Формат входа по описанию CMFormatDescription — не создаём AVAudioFormat на каждый кусок.
    private var formatCache: (CMFormatDescription, AVAudioFormat)?

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Первый запрос разрешения — только по действию человека (удержание ⌃⌥Space).
    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    /// Открыть вход (главная очередь). `done` — на главной: nil — слушаем, иначе почему нет.
    func start(_ pick: MicChoice.Pick, done: @escaping (String?) -> Void) {
        guard !running else { done(nil); return }
        guard Self.permission == .authorized else { done("нет доступа к микрофону"); return }
        running = true
        generation += 1
        let gen = generation
        queue.async {
            let why = self.open(pick, gen)
            DispatchQueue.main.async {
                // Не открылся прошлый `start`, а уже идёт новый — новый не трогаем.
                if why != nil, gen == self.generation { self.running = false }
                done(why)
            }
        }
    }

    private func open(_ pick: MicChoice.Pick, _ gen: Int) -> String? {
        let device: AVCaptureDevice?
        switch pick {
        case .device(let d): device = AVCaptureDevice(uniqueID: d.uid)
        case .systemDefault: device = AVCaptureDevice.default(for: .audio)
        }
        guard let device else { return "нет микрофона" }
        let s = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            s.beginConfiguration()
            guard s.canAddInput(input), s.canAddOutput(out) else { s.commitConfiguration(); return "микрофон занят" }
            s.addInput(input)
            s.addOutput(out)
            s.commitConfiguration()
        } catch {
            return "не открылся"
        }
        out.setSampleBufferDelegate(self, queue: queue)
        resampler = PcmResampler()
        formatCache = nil
        stats = Stats(device: device.localizedName)
        // Одна потеря — одно переключение: `wasDisconnected` и ошибка сессии обычно приходят обе.
        let lost: (String) -> Void = { [weak self] why in
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == gen, self.lostHandled != gen else { return }
                self.lostHandled = gen
                self.onLost?(why)
            }
        }
        observers = [
            NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
                lost("отключился")
            },
            NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: s, queue: nil) { _ in
                lost("ошибка входа")
            },
        ]
        session = s
        output = out
        s.startRunning()
        guard s.isRunning else {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            session = nil
            output = nil
            return "не включился"
        }
        return nil
    }

    /// Вход перестал отдавать звук (главная очередь, от `HearingWatch.stalled`): как потеря, один раз на открытие.
    func reportStall() {
        guard running, lostHandled != generation else { return }
        lostHandled = generation
        onLost?("перестал отдавать звук")
    }

    func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard captureOutput === output, let buf = pcm(sample) else { return }
        let pcm = resampler.convert(buf)
        guard !pcm.isEmpty else { return }
        if stats.format.isEmpty || resampler.formatChanges != stats.formatChanges {
            stats.format = Self.describe(buf.format)
            stats.formatChanges = resampler.formatChanges
        }
        let level = VoiceLevel.level(pcm)
        stats.seconds += Double(pcm.count) / PcmResampler.target.sampleRate
        stats.peak = max(stats.peak, level)
        onAudio?(pcm, level)
    }

    /// Закрыть вход (главная очередь). Хвост фильтра уходит в `onAudio` до `done` (та же очередь).
    func stop(done: ((Stats) -> Void)? = nil) {
        guard running else { return }
        running = false
        queue.async {
            for o in self.observers { NotificationCenter.default.removeObserver(o) }
            self.observers = []
            self.output?.setSampleBufferDelegate(nil, queue: nil)
            self.session?.stopRunning()
            self.session = nil
            self.output = nil
            let tail = self.resampler.flush()
            if !tail.isEmpty { self.onAudio?(tail, 0) }
            let st = self.stats
            if let done { DispatchQueue.main.async { done(st) } }
        }
    }

    /// CMSampleBuffer → AVAudioPCMBuffer в родном формате входа (Float32/Int16, любое число каналов, interleaved).
    /// Больше 2 каналов без раскладки AVAudioFormat не создаётся — берём раскладку из описания формата, нет её —
    /// раскладку «N отдельных каналов». Формат кэшируется по описанию (оно одно на поток кусков).
    private func pcm(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let format: AVAudioFormat
        if let c = formatCache, CFEqual(c.0, fd) {
            format = c.1
        } else {
            guard let f = Self.format(fd) else { return nil }
            formatCache = (fd, f)
            format = f
        }
        let n = CMSampleBufferGetNumSamples(sample)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }

    static func format(_ fd: CMFormatDescription) -> AVAudioFormat? {
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        if asbd.pointee.mChannelsPerFrame <= 2, let f = AVAudioFormat(streamDescription: asbd) { return f }
        var size = 0
        if let acl = CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size) {
            let layout = AVAudioChannelLayout(layout: acl)
            if layout.channelCount == asbd.pointee.mChannelsPerFrame { return AVAudioFormat(streamDescription: asbd, channelLayout: layout) }
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.pointee.mChannelsPerFrame) else { return nil }
        return AVAudioFormat(streamDescription: asbd, channelLayout: layout)
    }

    static func describe(_ f: AVAudioFormat) -> String {
        let kind: String = switch f.commonFormat {
        case .pcmFormatFloat32: "f32"
        case .pcmFormatInt16: "i16"
        case .pcmFormatInt32: "i32"
        case .pcmFormatFloat64: "f64"
        default: "?"
        }
        return "\(Int(f.sampleRate)) Гц \(f.channelCount) кан \(kind)\(f.isInterleaved && f.channelCount > 1 ? " interleaved" : "")"
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
