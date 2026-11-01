import Foundation
import CoreGraphics

/// Пузырь реплики у глаз (сцена `perch`).
public struct SceneBubble: Equatable {
    public var rect: CGRect
    /// Сколько букв напечатано.
    public var typed: Int
    public var caret: Bool
    /// Пузырь проступает/рассыпается полосами (глитч рамки).
    public var glitch: Bool
    /// Какая по счёту реплика сцены (терминал говорит несколько; посадка — одну).
    public var say = 0

    public init(rect: CGRect, typed: Int, caret: Bool, glitch: Bool = false, say: Int = 0) {
        self.rect = rect; self.typed = typed; self.caret = caret; self.glitch = glitch; self.say = say
    }
}

/// «Сидит на окне»: прилёт → пузырь с печатью реплики → сидит (моргает, косится, редкий глитч) → уход. 7–14 с.
/// Сидение рисуется по событию: следующий кадр — на ближайшее изменение (`nextChange`), а не 12 fps.
public enum PerchTimeline {
    /// Конец прилёта (из notch: уход 0,25 → молния 0,15 → появление 0,5).
    public static let arrive = 0.9
    /// Начало печати.
    public static let typeStart = 1.0
    /// Букв в секунду.
    public static let cps = 18.0
    public static let leaveLen = 0.75
    public static let minDuration = 7.0
    public static let maxDuration = 14.0
    /// Мини-прыжок, когда окно сдвинули.
    public static let hopLen = 0.2
    /// Моргание (`close`) и «косится» (клип `look` идёт) — длины.
    static let blinkLen = 0.3
    static let glanceLen = 1.0
    /// Шаги кадров: печать, взгляд, переходы.
    static let typeStep = 1.0 / 12
    static let glanceStep = 1.0 / 6
    static let fastStep = 1.0 / 24

    static func u(_ o: SceneOptions, _ salt: Int) -> Double { TickNoise.unit(o.seed, salt) }

    /// Конец печати.
    public static func typedAt(_ o: SceneOptions) -> Double { typeStart + Double(o.perchChars) / cps }

    /// Пузырь держится после печати 2,5–4 с, потом рассыпается — дальше просто сидит.
    public static func speakEnd(_ o: SceneOptions) -> Double { typedAt(o) + 2.5 + 1.5 * u(o, 961) }

    public static func duration(_ o: SceneOptions) -> Double {
        if let w = o.watch { return WatchTimeline.duration(w) }
        return min(maxDuration, max(minDuration, speakEnd(o) + 3 + 5 * u(o, 962) + leaveLen))
    }

    /// Спокойная часть (глаза на окне): горячие точки, удержание наведением.
    public static func calm(_ o: SceneOptions) -> Range<Double> {
        if let w = o.watch { return WatchTimeline.calm(w) }
        return arrive..<(duration(o) - leaveLen)
    }

    // MARK: события сидения

    /// Моргания: каждые ≈ 2,7 с с разбросом.
    static func blinks(_ o: SceneOptions) -> [Double] {
        let end = duration(o) - leaveLen
        var out: [Double] = []
        var t = arrive + 1.9 + 0.8 * u(o, 963)
        var k = 0
        while t + blinkLen < end {
            out.append(t)
            k += 1
            t += 2.3 + 0.9 * TickNoise.unit(k, 964 + o.seed)
        }
        return out
    }

    /// «Косится»: клип `look` идёт ≈ 1 с (6 кадров/с) раз в 5–6,5 с после печати, между — стоит.
    static func glances(_ o: SceneOptions) -> [Double] {
        let end = duration(o) - leaveLen
        var out: [Double] = []
        var t = speakEnd(o) + 0.6 + 0.8 * u(o, 965)
        var k = 0
        while t + glanceLen < end {
            out.append(t)
            k += 1
            t += 5.0 + 1.5 * TickNoise.unit(k, 966 + o.seed)
        }
        return out
    }

    /// Редкий глитч (2 кадра 24 fps) раз в ≈ 3,5 с.
    static func glitches(_ o: SceneOptions) -> [Double] {
        let end = duration(o) - leaveLen
        var out: [Double] = []
        var t = arrive + 2.6 + 1.0 * u(o, 967)
        var k = 0
        while t + 0.1 < end {
            out.append(t)
            k += 1
            t += 3.0 + 1.4 * TickNoise.unit(k, 968 + o.seed)
        }
        return out
    }

    /// Время клипа `look` в сидении: идёт только во время «косится» (иначе кадр стоит).
    static func lookTime(_ t: Double, _ o: SceneOptions) -> Double {
        glances(o).reduce(0) { acc, g in acc + min(glanceLen, max(0, t - g)) }
    }

    // MARK: кадр

    public static func frame(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> SceneFrame {
        if let w = o.watch { return WatchTimeline.frame(t, g, c, o, w) }
        let d = duration(o)
        let leave = d - leaveLen
        switch t {
        case ..<0.25: return SceneTimeline.out("out", at: g.home, t, len: 0.25, c)
        case ..<0.4: return SceneTimeline.jump("jump", from: g.home, to: g.target, t - 0.25, len: 0.15)
        case ..<arrive:
            var f = SceneTimeline.into("in", at: g.target, t - 0.4, len: arrive - 0.4, c)
            f.rig = RigMoments.base(o, t: t)
            return f
        case ..<leave: return sit(t, g, c, o)
        case ..<(leave + 0.3):
            var f = SceneTimeline.out("leave", at: SceneTimeline.lean(g.target, g), t - leave, len: 0.3, c)
            f.rig = RigMoments.base(o, t: t)
            return f
        case ..<(leave + 0.45): return SceneTimeline.jump("back", from: SceneTimeline.lean(g.target, g), to: g.home, t - leave - 0.3, len: 0.15)
        default:
            var f = SceneTimeline.into("home", at: g.home, t - leave - 0.45, len: leaveLen - 0.45, c)
            f.glitch = 2
            return f
        }
    }

    static func sit(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> SceneFrame {
        let eyes = SceneTimeline.lean(g.target, g)
        let typedAt = typedAt(o), speakEnd = speakEnd(o)
        let typing = t >= typeStart && t < typedAt
        var f = SceneFrame(phase: t < speakEnd ? "speak" : "sit", eyes: eyes)
        if typing, c.contains(SceneClip.talk) {
            f.clip = SceneClip.talk; f.clipT = t - typeStart
        } else {
            // Кадр `look` стоит; идёт только когда «косится».
            f.clip = SceneClip.look; f.clipT = lookTime(t, o)
        }
        if c.contains(SceneClip.close), let b = blinks(o).first(where: { t >= $0 && t < $0 + blinkLen }) {
            f.clip = SceneClip.close; f.clipT = t - b; f.loop = false
        }
        if let k = glitches(o).firstIndex(where: { t >= $0 && t < $0 + 2.0 / 24 }) {
            f.glitch = TickNoise.unit(k, 969 + o.seed) < 0.3 ? 2 : 1
        }
        // Пузырь: проступает (0,1 с), печать с кареткой, на последней букве — глитч 1; держится, рассыпается 0,15 с.
        if let r = g.bubble, t >= typeStart - 0.1, t < speakEnd + 0.15 {
            let n = min(o.perchChars, max(0, Int((t - typeStart) * cps)))
            let caret = n < o.perchChars || Int(t * 2.5) % 2 == 0
            f.bubble = SceneBubble(rect: r, typed: n, caret: caret, glitch: t < typeStart || t >= speakEnd)
            if t >= typedAt, t < typedAt + 0.1 { f.glitch = max(f.glitch, 1) }
        }
        // Мини-маска: машет при прилёте, говорит, скучает, зевает, моргает, косится.
        let look = glances(o).first { t >= $0 && t < $0 + glanceLen }.map { (t - $0) / glanceLen }
        let blink = blinks(o).first { t >= $0 && t < $0 + blinkLen }.map { 1 - abs(2 * (t - $0) / blinkLen - 1) }
        f.rig = RigMoments.perch(t, g, o, look: look, blink: blink)
        // Окно тащат — держится на месте, чуть сплющена.
        if o.perchHold {
            f.glitch = max(f.glitch, 1)
            f.squash = 0.9
        }
        // Окно сдвинули — мини-прыжок с прошлого места (короткая молния, если далеко).
        if let h = o.hopAt, let from = o.hopFrom, t >= h, t < h + hopLen {
            let p = CGFloat((t - h) / hopLen)
            let e = p * p * (3 - 2 * p)
            let r = CGRect(x: from.minX + (eyes.minX - from.minX) * e, y: from.minY + (eyes.minY - from.minY) * e,
                           width: eyes.width, height: eyes.height)
            f.phase = "hop"
            f.eyes = r
            f.squash = 0.8 + 0.2 * abs(1 - 2 * p)
            f.glitch = 2
            f.bubble = nil
            f.rig?.set(.none)
            if hypot(eyes.midX - from.midX, eyes.midY - from.midY) > 40, p < 0.6 {
                f.bolt = SceneBolt(from: SceneTimeline.center(from), to: SceneTimeline.center(eyes), seed: Int(t * 12), reach: min(1, p / 0.5))
            }
        }
        return f
    }

    // MARK: расписание кадров

    /// Когда кадр в следующий раз изменится после `t` (в сидении — по событию). Вне сидения — 24 fps.
    /// Внутри анимированного куска (печать, моргание, «косится», глитч, прыжок) — его шаг, но не дальше ближайшей
    /// границы любого события: кадр не перескакивает начало или конец моргания.
    public static func nextChange(after t: Double, _ o: SceneOptions) -> Double {
        let calm = calm(o)
        guard calm.contains(t) else { return t + fastStep }
        let typedAt = typedAt(o), speakEnd = speakEnd(o)
        // Отрезки [начало, конец) с шагом кадра внутри.
        var spans: [(Double, Double, Double)] = [
            (typeStart - 0.1, typeStart, fastStep),
            (typeStart, typedAt + 0.1, typeStep),
            (speakEnd, speakEnd + 0.15, fastStep),
        ]
        spans += blinks(o).map { ($0, $0 + blinkLen, typeStep) }
        spans += glances(o).map { ($0, $0 + glanceLen, glanceStep) }
        spans += glitches(o).map { ($0, $0 + 2.0 / 24, fastStep) }
        if let h = o.hopAt { spans.append((h, h + hopLen, fastStep)) }
        // Риг: машет при прилёте, зевает.
        spans.append((arrive, arrive + RigMoments.waveLen, typeStep))
        if RigMoments.yawns(o) { spans.append((RigMoments.yawnAt(o), RigMoments.yawnAt(o) + RigMoments.yawnLen, typeStep)) }
        var next = calm.upperBound
        if o.perchHold { next = min(next, t + typeStep) }
        for (a, b, step) in spans {
            if t >= a - 1e-6, t < b { next = min(next, t + step, b) }
            if a > t + 1e-6 { next = min(next, a) }
            if b > t + 1e-6 { next = min(next, b) }
        }
        // Каретка мигает, пока пузырь виден (2,5 Гц).
        if t < speakEnd { next = min(next, (floor(t * 2.5) + 1) / 2.5) }
        // Чуть позже границы: кадр точно попадает внутрь события (сумма шагов с плавающей точкой).
        return next + 0.0005
    }

    /// Шаг до следующего кадра (не меньше 1/24 с, не больше 1 с — чтобы удержание и обрыв подхватывались).
    public static func step(_ t: Double, _ o: SceneOptions) -> Double {
        if let w = o.watch { return WatchTimeline.step(t, o, w) }
        return min(1, max(fastStep, nextChange(after: t, o) - t))
    }
}
