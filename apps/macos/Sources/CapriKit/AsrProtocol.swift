import Foundation

// Протокол между Capri и хелпером распознавания речи `capri-asr` (tools/capri-asr). Этот же файл собирается
// в хелпер (символическая ссылка), поэтому здесь только Foundation.
//
// stdin хелпера — управляющие строки, после `audio <байты>` — ровно столько байт PCM 16 кГц mono Float32 LE:
//   begin [язык]   — новая фраза (язык — подсказка, пусто — автоопределение)
//   audio <n>      — n байт звука (n кратно 4)
//   end            — фраза закончилась: финальный текст
//   cancel         — забыть фразу
//   quit           — выйти
// stdout — по JSON-объекту на строку (`AsrEvent`).

public enum AsrCommand: Equatable {
    case begin(language: String?)
    case audio([Float])
    case end
    case cancel
    case quit

    /// Байты команды для stdin хелпера.
    public var encoded: Data {
        switch self {
        case .begin(let lang):
            let l = lang.map { AsrCommand.cleanLanguage($0) } ?? ""
            return Data((l.isEmpty ? "begin\n" : "begin \(l)\n").utf8)
        case .audio(let pcm):
            var d = Data("audio \(pcm.count * 4)\n".utf8)
            pcm.withUnsafeBufferPointer { buf in
                for v in buf { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
            }
            return d
        case .end: return Data("end\n".utf8)
        case .cancel: return Data("cancel\n".utf8)
        case .quit: return Data("quit\n".utf8)
        }
    }

    /// Язык — только буквы и дефис, до 8 знаков (подсказка вида `ru`, `en-US`).
    static func cleanLanguage(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == "-" }.prefix(8).map(Character.init))
    }
}

/// Разбор stdin хелпера по кусочкам: строки и звук приходят как попало порезанными.
public struct AsrCommandReader {
    /// Больше 10 с звука одной командой не бывает (Capri шлёт по ~100 мс) — иначе поток испорчен.
    public static let maxAudioBytes = 16_000 * 4 * 10
    private var buffer = Data()
    /// Ждём столько байт звука.
    private var pending: Int?
    /// Поток испорчен (неизвестная команда, плохой размер): дальше не читаем.
    public private(set) var broken: String?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [AsrCommand] {
        guard broken == nil else { return [] }
        buffer.append(chunk)
        var out: [AsrCommand] = []
        while true {
            if let n = pending {
                guard buffer.count >= n else { break }
                let payload = buffer.prefix(n)
                buffer.removeFirst(n)
                pending = nil
                out.append(.audio(Self.floats(payload)))
                continue
            }
            guard let nl = buffer.firstIndex(of: 0x0A) else {
                if buffer.count > 256 { broken = "строка без конца" }
                break
            }
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(buffer.startIndex...nl)
            buffer = Data(buffer)   // индексы снова с нуля
            if line.isEmpty { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            switch parts[0] {
            case "begin": out.append(.begin(language: parts.count > 1 ? AsrCommand.cleanLanguage(parts[1]) : nil))
            case "end": out.append(.end)
            case "cancel": out.append(.cancel)
            case "quit": out.append(.quit)
            case "audio":
                guard parts.count > 1, let n = Int(parts[1]), n >= 0, n % 4 == 0, n <= Self.maxAudioBytes else {
                    broken = "плохой размер звука"
                    return out
                }
                if n == 0 { out.append(.audio([])) } else { pending = n }
            default:
                broken = "неизвестная команда"
                return out
            }
        }
        return out
    }

    static func floats(_ d: Data) -> [Float] {
        var out = [Float](repeating: 0, count: d.count / 4)
        d.withUnsafeBytes { raw in
            for i in 0..<out.count {
                let bits = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                out[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return out
    }
}

/// Строка stdout хелпера.
public enum AsrEvent: Equatable {
    /// Модель загружена.
    case ready(backend: String, loadMs: Int)
    /// Частичный текст фразы (весь, не приращение).
    case partial(String)
    /// Финальный текст фразы; `language` — что определила модель (если сказала).
    case final(String, language: String?)
    case cancelled
    case error(String)
    /// Хелпер выходит сам (простой) — память вернулась.
    case idle

    public var line: String {
        var obj: [String: Any]
        switch self {
        case .ready(let b, let ms): obj = ["event": "ready", "backend": b, "loadMs": ms]
        case .partial(let t): obj = ["event": "partial", "text": t]
        case .final(let t, let l):
            obj = ["event": "final", "text": t]
            if let l { obj["language"] = l }
        case .cancelled: obj = ["event": "cancelled"]
        case .error(let m): obj = ["event": "error", "message": m]
        case .idle: obj = ["event": "idle"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Разбор строки stdout; мусор (логи библиотеки, обрезанная строка) — nil.
    public static func parse(_ line: String) -> AsrEvent? {
        let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("{"), let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = obj["event"] as? String else { return nil }
        switch kind {
        case "ready": return .ready(backend: obj["backend"] as? String ?? "?", loadMs: (obj["loadMs"] as? NSNumber)?.intValue ?? 0)
        case "partial": return (obj["text"] as? String).map(AsrEvent.partial)
        case "final":
            guard let t = obj["text"] as? String else { return nil }
            return .final(t, language: obj["language"] as? String)
        case "cancelled": return .cancelled
        case "error": return .error(obj["message"] as? String ?? "ошибка")
        case "idle": return .idle
        default: return nil
        }
    }
}

/// Делит поток stdout на строки (приходит кусками).
public struct LineSplitter {
    private var buffer = Data()
    public init() {}
    public mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
            buffer = Data(buffer)
        }
        // Строка без конца длиннее 1 МБ — мусор.
        if buffer.count > 1 << 20 { buffer.removeAll() }
        return lines
    }
}

/// Где взять модель: путь из настроек, иначе кэш Hugging Face (`~/.cache/huggingface/hub`), иначе нет.
public enum AsrModel {
    public static let repo = "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf"
    public static let file = "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf"
    /// Снимок репозитория, с которого качаем (не `main`: файл под ним может поменяться), и SHA-256 файла — его
    /// проверяем до того, как ggml начнёт разбирать скачанное (сверено с блобом кэша HF на Маке, 751 094 240 байт).
    public static let revision = "6d44e540bc31b0de1dbe174a3cea87f53a7f22fb"
    public static let sha256 = "b94545b313b3223fda7b2857a52681da813935c2127643d1e9ff0c23d988089c"
    public static let size: Int64 = 751_094_240
    /// Откуда скачать, если в кэше нет (только по кнопке в настройках).
    public static var downloadURL: URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")! }
    /// Куда скачивать сами (не в кэш HF, чтобы не путать его учёт).
    public static func ownPath(home: String) -> String { home + "/.capri/models/" + file }

    /// Каталог репозитория в кэше HF (`HF_HUB_CACHE`, `HF_HOME/hub`, иначе `~/.cache/huggingface/hub`).
    public static func cacheDir(home: String, env: [String: String]) -> String {
        if let c = env["HF_HUB_CACHE"], !c.isEmpty { return c + "/models--" + repo.replacingOccurrences(of: "/", with: "--") }
        let hub = env["HF_HOME"].map { $0 + "/hub" } ?? home + "/.cache/huggingface/hub"
        return hub + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
    }

    /// Путь к модели или nil. `override` — из настроек (пусто — искать). Снимок `refs/main` — первым, потом
    /// остальные по имени (свежие коммиты не упорядочены, но файл в них один и тот же).
    public static func locate(override: String?, home: String, env: [String: String],
                              exists: (String) -> Bool, read: (String) -> String?, list: (String) -> [String]) -> String? {
        if let o = override?.trimmingCharacters(in: .whitespaces), !o.isEmpty {
            let p = o.hasPrefix("~/") ? home + o.dropFirst(1) : o
            return exists(p) ? p : nil
        }
        let dir = cacheDir(home: home, env: env)
        var snapshots: [String] = []
        if let main = read(dir + "/refs/main")?.trimmingCharacters(in: .whitespacesAndNewlines), !main.isEmpty, !main.contains("/") {
            snapshots.append(main)
        }
        snapshots += list(dir + "/snapshots").sorted().filter { !snapshots.contains($0) }
        for s in snapshots {
            let p = dir + "/snapshots/" + s + "/" + file
            if exists(p) { return p }
        }
        let own = ownPath(home: home)
        return exists(own) ? own : nil
    }
}
