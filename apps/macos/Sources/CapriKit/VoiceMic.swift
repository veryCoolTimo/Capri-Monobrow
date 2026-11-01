import Foundation
import CoreGraphics

// Микрофон голоса без Мака: какой вход взять (по умолчанию — встроенный, он не переключает AirPods в гарнитуру),
// громкость, «не слышу», рот-зигзаг в notch и подсказка в помощнике.

/// Вход звука (CoreAudio): UID, имя, тип подключения.
public struct MicDevice: Equatable, Sendable {
    public enum Transport: Equatable, Sendable { case builtIn, bluetooth, usb, virtual, continuity, other }
    public var uid: String
    public var name: String
    public var transport: Transport

    public init(uid: String, name: String, transport: Transport) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    /// По коду `kAudioDevicePropertyTransportType` ('bltn', 'blue', 'bleo', 'usb ', 'virt', 'ccwd').
    public static func transport(code: UInt32) -> Transport {
        switch code {
        case 0x626C_746E: .builtIn
        case 0x626C_7565, 0x626C_656F: .bluetooth
        case 0x7573_6220: .usb
        case 0x7669_7274, 0x6772_7570, 0x6167_6772: .virtual   // виртуальный, агрегатный
        case 0x6363_7764: .continuity
        default: .other
        }
    }
}

/// Что выбрано в Настройках → Голос → Микрофон. Хранится строкой: `builtin`, `default`, `uid:<UID>`.
public enum MicPreference: Equatable, Sendable {
    case builtIn
    case systemDefault
    case device(uid: String)

    public init(stored: String?) {
        switch stored {
        case nil, "", "builtin": self = .builtIn
        case "default": self = .systemDefault
        case let s? where s.hasPrefix("uid:") && s.count > 4: self = .device(uid: String(s.dropFirst(4)))
        default: self = .builtIn
        }
    }

    public var stored: String {
        switch self {
        case .builtIn: "builtin"
        case .systemDefault: "default"
        case .device(let uid): "uid:" + uid
        }
    }
}

/// Какой вход открыть и что сказать в notch, если выбранного нет.
public enum MicChoice {
    public enum Pick: Equatable, Sendable {
        /// Этот вход — не трогая системный по умолчанию.
        case device(MicDevice)
        /// Системный по умолчанию (что выбрано в macOS).
        case systemDefault
    }

    public struct Resolution: Equatable, Sendable {
        public var pick: Pick
        /// Выбранного нет — взяли другой (строка в notch); nil — всё как выбрано.
        public var note: String?
        public init(pick: Pick, note: String?) { self.pick = pick; self.note = note }
    }

    /// Выбранный вход; пропал — встроенный, нет и его — системный по умолчанию. `savedName` — имя выбранного
    /// (запомнено при выборе), чтобы сказать, какого именно нет.
    public static func resolve(_ pref: MicPreference, devices: [MicDevice], savedName: String? = nil) -> Resolution {
        let builtIn = devices.first { $0.transport == .builtIn }
        switch pref {
        case .systemDefault:
            return Resolution(pick: .systemDefault, note: nil)
        case .builtIn:
            if let b = builtIn { return Resolution(pick: .device(b), note: nil) }
            return Resolution(pick: .systemDefault, note: "Встроенного микрофона нет — слушаю системный")
        case .device(let uid):
            if let d = devices.first(where: { $0.uid == uid }) { return Resolution(pick: .device(d), note: nil) }
            let name = savedName.map { "«\(short($0))»" } ?? "Выбранный микрофон"
            if let b = builtIn { return Resolution(pick: .device(b), note: "\(name) не подключён — слушаю встроенный") }
            return Resolution(pick: .systemDefault, note: "\(name) не подключён — слушаю системный")
        }
    }

    /// Вход пропал или встал посреди фразы: список CoreAudio может ещё держать ушедший вход — его выкидываем.
    /// Порядок: встроенный → системный по умолчанию (если это не ушедший) → любой оставшийся; nil — входов нет.
    public static func fallback(lost: String?, devices: [MicDevice], defaultUID: String?, why: String) -> Resolution? {
        let left = devices.filter { $0.uid != lost }
        if let b = left.first(where: { $0.transport == .builtIn }) {
            return Resolution(pick: .device(b), note: "Микрофон \(why) — слушаю встроенный")
        }
        if let d = defaultUID, d != lost, left.contains(where: { $0.uid == d }) {
            return Resolution(pick: .systemDefault, note: "Микрофон \(why) — слушаю системный")
        }
        if let any = left.first { return Resolution(pick: .device(any), note: "Микрофон \(why) — слушаю «\(short(any.name))»") }
        return nil
    }

    /// UID того, что реально откроется (системный — по UID входа по умолчанию).
    public static func uid(_ pick: Pick, defaultUID: String?) -> String? {
        switch pick {
        case .device(let d): d.uid
        case .systemDefault: defaultUID
        }
    }

    /// Bluetooth — «медленный» вход: первые 1–2 с теряются, терпения «не слышу» больше.
    public static func slow(_ pick: Pick, devices: [MicDevice], defaultUID: String?) -> Bool {
        guard let u = uid(pick, defaultUID: defaultUID) else { return false }
        return devices.first { $0.uid == u }?.transport == .bluetooth
    }

    /// Пункты выбора в настройках: встроенный, системный, остальные входы; выбранный, но отключённый — тоже
    /// (чтобы выбор не сбрасывался молча, пока наушники в футляре).
    public struct Option: Equatable, Sendable {
        public var tag: String
        public var title: String
    }

    public static func options(devices: [MicDevice], defaultUID: String?, pref: MicPreference, savedName: String?) -> [Option] {
        let builtIn = devices.first { $0.transport == .builtIn }
        var out = [Option(tag: MicPreference.builtIn.stored,
                          title: builtIn.map { "Встроенный — \($0.name)" } ?? "Встроенный (нет)")]
        let def = devices.first { $0.uid == defaultUID }
        out.append(Option(tag: MicPreference.systemDefault.stored,
                          title: "Системный по умолчанию" + (def.map { " (\($0.name))" } ?? "")))
        for d in devices where d.uid != builtIn?.uid {
            out.append(Option(tag: MicPreference.device(uid: d.uid).stored, title: d.name + slowNote(d)))
        }
        if case .device(let uid) = pref, !devices.contains(where: { $0.uid == uid }) {
            out.append(Option(tag: pref.stored, title: (savedName ?? "Выбранный микрофон") + " (не подключён)"))
        }
        return out
    }

    /// Bluetooth-гарнитура: macOS переключает её в режим гарнитуры, первые 1–2 с звука теряются.
    public static func slowNote(_ d: MicDevice) -> String {
        d.transport == .bluetooth ? " — Bluetooth, первые 1–2 с теряются" : ""
    }

    static func short(_ s: String) -> String { s.count > 28 ? String(s.prefix(27)) + "…" : s }
}

/// Громкость микрофона для notch: RMS куска → 0…1 (−50 дБFS — тишина, −10 дБFS — громко).
public enum VoiceLevel {
    public static func level(_ pcm: [Float]) -> Double {
        guard !pcm.isEmpty else { return 0 }
        var sum: Float = 0
        for v in pcm { sum += v * v }
        return level(rms: Double((sum / Float(pcm.count)).squareRoot()))
    }

    public static func level(rms: Double) -> Double {
        let db = 20 * log10(max(1e-6, rms))
        return max(0, min(1, (db + 50) / 40))
    }

    /// Выше — это голос, а не шум комнаты (≈ −40 дБFS RMS за 100 мс; встроенный микрофон в тишине ≈ −55).
    public static let heard = 0.25

    /// Голос, а не тишина: рот шевелится и бьёт молния только выше порога.
    public static func speaking(_ level: Double) -> Bool { level >= heard }

    /// Плавная громкость для рта и молнии: подскок сразу, спад — за ~0.3 с (кадры 12 fps).
    public static func smooth(_ previous: Double, _ new: Double) -> Double {
        new >= previous ? previous + (new - previous) * 0.75 : previous + (new - previous) * 0.3
    }
}

/// «Не слышу»: часы идут с первого куска звука, а не с нажатия (микрофон включается после начала удержания,
/// Bluetooth теряет первые 1–2 с, человек молчит полсекунды перед словом). Куски идут, но всё тихо дольше
/// `patience` — «тихо»; кусков нет совсем дольше `deadline` — «микрофон молчит». Голос — это `loudFor` подряд
/// громче шума (щелчок клавиши — 10–20 мс — не голос). Услышали — строка снова «слушаю», больше не возвращается.
/// После голоса куски перестали приходить на `stallAfter` — захват встал молча (`stalled`).
public struct HearingWatch: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case waiting, heard
        /// Звук идёт, но тихий — «говори ближе».
        case quiet
        /// Ни одного куска — микрофон молчит совсем.
        case dead
    }

    /// Встроенный — 1.5 с, Bluetooth — 2 с (с первого куска).
    public static func patience(slow: Bool) -> Double { slow ? 2.0 : 1.5 }
    /// Без единого куска с нажатия: встроенный — 2.5 с, Bluetooth — 3.5 с (гарнитура включается до 2 с).
    public static func deadline(slow: Bool) -> Double { slow ? 3.5 : 2.5 }
    public static let loudFor = 0.08
    public static let stallAfter = 0.5

    public private(set) var start: Double
    public let slow: Bool
    public private(set) var firstChunk: Double?
    public private(set) var lastChunk: Double?
    public private(set) var heardAt: Double?
    /// Сколько кусков звука вообще пришло (0 — микрофон молчит совсем, а не тихо).
    public private(set) var chunks = 0
    public private(set) var peak: Double = 0
    private var loudRun = 0.0

    public init(start: Double, slow: Bool = false) { self.start = start; self.slow = slow }

    /// Кусок длиной `seconds` с громкостью `level` пришёл в момент `t`.
    public mutating func feed(level: Double, at t: Double, seconds: Double = 0.1) {
        chunks += 1
        if firstChunk == nil { firstChunk = t }
        lastChunk = t
        peak = max(peak, level)
        guard heardAt == nil else { return }
        if level >= VoiceLevel.heard {
            loudRun += max(0, seconds)
            if loudRun >= Self.loudFor - 1e-9 { heardAt = t }
        } else {
            loudRun = 0
        }
    }

    public func status(at t: Double) -> Status {
        if heardAt != nil { return .heard }
        guard let first = firstChunk else {
            return t - start >= Self.deadline(slow: slow) - 1e-9 ? .dead : .waiting
        }
        return t - first >= Self.patience(slow: slow) - 1e-9 ? .quiet : .waiting
    }

    /// Куски шли и перестали дольше `stallAfter` — вход встал молча (AirPods ушли в гарнитуру посреди фразы).
    public func stalled(at t: Double) -> Bool {
        guard let last = lastChunk else { return false }
        return t - last >= Self.stallAfter - 1e-9
    }

    public static let deadText = "микрофон молчит — проверь Настройки → Голос"
    public static let quietText = "тихо — говори ближе"

    public static func text(_ s: Status) -> String? {
        switch s {
        case .dead: deadText
        case .quiet: quietText
        case .waiting, .heard: nil
        }
    }
}

/// Рот Capri, пока она слушает: розовый зигзаг рядом с глазами, высота колен — по громкости, колени «кипят»
/// каждый кадр. Точки в прямоугольнике `rect` (y вниз), середина — `rect.midY`.
public enum VoiceMouth {
    public static func points(in rect: CGRect, tick: Int, level: Double, knees: Int = 7) -> [CGPoint] {
        let lv = CGFloat(max(0, min(1, level)))
        let n = max(3, knees)
        // Тишина (ниже порога голоса) — ровная черта: видно, что голоса нет; голос — колени во всю высоту.
        guard Double(lv) >= VoiceLevel.heard else { return (0..<n).map { CGPoint(x: rect.minX + rect.width * CGFloat($0) / CGFloat(n - 1), y: rect.midY) } }
        let amp = rect.height / 2 * (0.2 + 0.8 * lv)
        var out: [CGPoint] = []
        for k in 0..<n {
            let f = CGFloat(k) / CGFloat(n - 1)
            let x = rect.minX + rect.width * f
            guard k > 0, k < n - 1 else { out.append(CGPoint(x: x, y: rect.midY)); continue }
            let side: CGFloat = k % 2 == 0 ? 1 : -1
            // Середина выше краёв: зигзаг — как губы, не как пила.
            let envelope = 0.45 + 0.55 * sin(.pi * f)
            let boil = 0.55 + 0.45 * CGFloat(TickNoise.unit(tick, 60 + k))
            out.append(CGPoint(x: x, y: rect.midY + side * amp * envelope * boil))
        }
        return out
    }
}

/// Подсказка в помощнике: «держи ⌃⌥Пробел — скажи голосом», пока голосом не воспользовались 3 раза.
public enum VoiceHint {
    public static let text = "держи ⌃⌥Пробел — скажи голосом"
    public static let enough = 3

    public static func show(voiceOn: Bool, successes: Int) -> Bool { voiceOn && successes < enough }
}
