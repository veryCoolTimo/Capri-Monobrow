import Foundation
import TranscribeCpp

// capri-asr — потоковое распознавание речи для Capri (push-to-talk). Модель грузится один раз; по stdin — фразы
// (`AsrCommand`), по stdout — JSON-строки (`AsrEvent`). Сам выходит после простоя (память модели возвращается),
// и когда Capri закрыла stdin. Выход — `_exit`: деструкторы ggml-metal на выходе процесса не нужны.
//
//   capri-asr --model PATH [--idle 300]
//   capri-asr --model PATH --file x.wav     — проверка: распознать wav (16 кГц mono s16) как одну фразу

let args = CommandLine.arguments
func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let out = NSLock()
func emit(_ e: AsrEvent) {
    out.lock()
    FileHandle.standardOutput.write(Data((e.line + "\n").utf8))
    out.unlock()
}
func die(_ message: String) -> Never {
    emit(.error(message))
    _exit(1)
}

guard let modelPath = value("--model") else { die("нет --model") }
guard FileManager.default.fileExists(atPath: modelPath) else { die("нет модели: \(modelPath)") }
let idleLimit = Double(value("--idle") ?? "") ?? 300
if !args.contains("--verbose") { Transcribe.disableLogging() }

let started = Date()
let model: Model
let session: Session
do {
    model = try Model(path: modelPath)
    session = try model.session()
} catch {
    die("модель не загрузилась: \(error)")
}
emit(.ready(backend: model.backend, loadMs: Int(Date().timeIntervalSince(started) * 1000)))

/// Последнее действие (для выхода по простою) и идёт ли фраза — под замком: таймер простоя на другой очереди.
final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var busy = false
    func touch(busy b: Bool? = nil) { lock.lock(); last = Date(); if let b { busy = b }; lock.unlock() }
    /// Простой дольше `limit` — выйти (под замком: команда, пришедшая в этот миг, ждёт замок и выход не проскочит
    /// мимо неё — её `touch` уже отметился бы). «Занят» без звука дольше 60 с — тоже простой: Capri потеряла фразу
    /// (не прислала ни `end`, ни `cancel`), а 180 МБ модели не должны висеть вечно.
    func exitIfIdle(limit: Double, _ exit: () -> Never) {
        lock.lock()
        let since = Date().timeIntervalSince(last)
        if busy ? since > 60 : since > limit { exit() }
        lock.unlock()
    }
}
let activity = Activity()

var stream: TranscribeCpp.Stream?
var lastPartial = ""
var heard = 0

func begin(_ language: String?) {
    stream?.reset()
    stream = nil
    lastPartial = ""
    heard = 0
    var ro = RunOptions()
    ro.language = language
    do {
        stream = try session.stream(ro, StreamOptions())
        activity.touch(busy: true)
    } catch {
        emit(.error("stream: \(error)"))
        activity.touch(busy: false)
    }
}

func feed(_ pcm: [Float]) {
    guard let s = stream, !pcm.isEmpty else { return }
    activity.touch()
    heard += pcm.count
    do {
        let u = try s.feed(pcm)
        if u.committedChanged || u.tentativeChanged {
            let text = s.text.display.trimmingCharacters(in: .whitespacesAndNewlines)
            if text != lastPartial { lastPartial = text; emit(.partial(text)) }
        }
    } catch {
        emit(.error("feed: \(error)"))
        stream = nil
        activity.touch(busy: false)
    }
}

func end() {
    defer { stream = nil; activity.touch(busy: false) }
    guard let s = stream else { emit(.final("", language: nil)); return }
    do {
        try s.finalize()
        let text = s.text.full.trimmingCharacters(in: .whitespacesAndNewlines)
        emit(.final(text, language: s.snapshot.language))
    } catch {
        emit(.error("finalize: \(error)"))
    }
}

func cancel() {
    stream?.reset()
    stream = nil
    activity.touch(busy: false)
    emit(.cancelled)
}

// Проверка на wav без Capri: та же дорога, что у живого звука (кусками по 100 мс).
if let wav = value("--file") {
    guard let d = FileManager.default.contents(atPath: wav), d.count > 44 else { die("нет wav") }
    let pcm: [Float] = d.subdata(in: 44..<d.count).withUnsafeBytes { raw in
        (0..<(raw.count / 2)).map { Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
    }
    let t0 = Date()
    begin(value("--language"))
    var i = 0
    while i < pcm.count { feed(Array(pcm[i..<min(i + 1600, pcm.count)])); i += 1600 }
    let t1 = Date()
    end()
    FileHandle.standardError.write(Data(String(format: "audio %.1f s, feed %.0f ms, finalize %.0f ms\n",
                                               Double(pcm.count) / 16000, t1.timeIntervalSince(t0) * 1000,
                                               Date().timeIntervalSince(t1) * 1000).utf8))
    _exit(0)
}

// Простой: никого не слушаем `idleLimit` секунд — выходим (Capri запустит снова при следующем нажатии).
let idleTimer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
idleTimer.schedule(deadline: .now() + 15, repeating: 15)
idleTimer.setEventHandler {
    activity.exitIfIdle(limit: idleLimit) {
        emit(.idle)
        _exit(0)
    }
}
idleTimer.resume()

var reader = AsrCommandReader()
let stdin = FileHandle.standardInput
while true {
    let chunk = stdin.availableData
    if chunk.isEmpty { _exit(0) }   // Capri закрыла pipe (или её нет)
    for cmd in reader.feed(chunk) {
        switch cmd {
        case .begin(let lang): begin(lang)
        case .audio(let pcm): feed(pcm)
        case .end: end()
        case .cancel: cancel()
        case .quit: _exit(0)
        }
    }
    if let why = reader.broken { die("stdin: \(why)") }
}
