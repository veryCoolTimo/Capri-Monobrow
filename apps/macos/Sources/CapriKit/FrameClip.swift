import Foundation

/// Клип «на держаниях», как рисованная анимация: рисунок `i` держится `holds[i]` тиков (тик = 1/12 с).
public struct FrameClip: Equatable {
    /// Сколько тиков держится каждый рисунок (≥ 1).
    public var holds: [Int]
    /// Номер рисунка в общем списке кадров для каждой позиции клипа.
    public var frames: [Int]

    public init(frames: [Int], holds: [Int]) {
        precondition(frames.count == holds.count)
        self.frames = frames
        self.holds = holds.map { min(max(1, $0), Self.maxHold) }
    }

    /// Самое долгое держание (5 мин): опечатка в `clips.json` не переполнит счёт.
    public static let maxHold = 3600

    /// Длина в тиках.
    public var total: Int { holds.reduce(0, +) }

    /// Рисунок в тике `tick`: по кругу (`loop`) или с остановкой на последнем. Пустой клип — nil.
    public func frame(at tick: Int, loop: Bool) -> Int? {
        guard !frames.isEmpty else { return nil }
        var k = max(0, tick)
        if loop { k %= total } else if k >= total { return frames.last }
        for (i, h) in holds.enumerated() {
            if k < h { return frames[i] }
            k -= h
        }
        return frames.last
    }

    /// Тот же клип, но ни один рисунок не держится дольше `cap` тиков.
    public func capped(_ cap: Int) -> FrameClip {
        FrameClip(frames: frames, holds: holds.map { min($0, cap) })
    }

    /// Клип с последним рисунком, удержанным `hold` тиков.
    public func holdingLast(_ hold: Int) -> FrameClip {
        guard !holds.isEmpty else { return self }
        var h = holds
        h[h.count - 1] = hold
        return FrameClip(frames: frames, holds: h)
    }

    public static func + (a: FrameClip, b: FrameClip) -> FrameClip {
        FrameClip(frames: a.frames + b.frames, holds: a.holds + b.holds)
    }
}

/// Детерминированный шум для эффектов: одно и то же число на один и тот же тик (все виды Capri синхронны).
public enum TickNoise {
    public static func hash(_ x: Int, _ salt: Int = 0) -> UInt64 {
        var z = UInt64(bitPattern: Int64(x)) &+ UInt64(bitPattern: Int64(salt)) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Число в [0, 1).
    public static func unit(_ x: Int, _ salt: Int = 0) -> Double {
        Double(hash(x, salt) >> 11) / Double(1 << 53)
    }

    /// Вспышка в тике `tick`: раз в `period` тиков на `length` тиков, начало внутри периода — случайное.
    /// Возвращает номер вспышки (для её формы) или nil.
    public static func burst(_ tick: Int, period: Int, length: Int, salt: Int = 0) -> Int? {
        guard period > length, length > 0 else { return nil }
        let beat = tick / period, phase = tick % period
        let start = Int(hash(beat, salt) % UInt64(period - length))
        return phase >= start && phase < start + length ? beat : nil
    }
}
