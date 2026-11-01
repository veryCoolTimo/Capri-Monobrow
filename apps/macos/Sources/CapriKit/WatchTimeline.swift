import Foundation
import CoreGraphics

/// Реплика в сцене «смотрит в терминал»: когда начинается печать (время таймлайна) и сколько букв.
public struct SceneSay: Equatable {
    public var at: Double
    public var chars: Int
    public init(at: Double, chars: Int) { self.at = at; self.chars = chars }
}

/// Сцена «смотрит в терминал» (этап 3 присутствия): окно терминала, реплики по ходу, конец.
public struct SceneWatch: Equatable {
    /// Рамка окна терминала (глобально, AppKit): по ней — красный размаз на входе.
    public var window: CGRect
    public var says: [SceneSay]
    /// Когда перестаёт смотреть сама (время таймлайна): ≤ 60 с от начала.
    public var end: Double
    /// Сессия доработала/упала: злорадствует с этого момента, потом уходит.
    public var gloatAt: Double?
    /// Связь с хостом сессии потеряна: с этого момента рассыпается пиксельным призраком, потом уходит.
    public var ghostAt: Double?

    public init(window: CGRect, says: [SceneSay] = [], end: Double = WatchTimeline.maxWatch, gloatAt: Double? = nil,
                ghostAt: Double? = nil) {
        self.window = window; self.says = says; self.end = end; self.gloatAt = gloatAt; self.ghostAt = ghostAt
    }
}

/// «Смотрит в терминал»: молния в окно терминала → окно краснеет и стекает столбцами → из угла натекает и садится на
/// край → смотрит (моргает, косится), реплики на перемены в сессии → злорадство (прищур + дрожь) или просто уход.
/// Покой рисуется по событию (`nextChange`), как у посадки на окно.
public enum WatchTimeline {
    public static let maxWatch = 60.0
    /// Молния из notch в терминал кончается здесь, потом размаз.
    public static let smearStart = 0.4
    public static let smearLen = 0.6
    /// Вылезает (натекает столбцами) на край окна.
    public static let climbLen = 0.5
    public static var arrive: Double { smearStart + smearLen + climbLen }
    /// Первая реплика — сразу после прилёта.
    public static var firstSay: Double { arrive + 0.1 }
    /// Пузырь держится после печати.
    public static let hold = 4.0
    public static let gloatLen = 2.4
    public static let leaveLen = PerchTimeline.leaveLen
    static let cps = PerchTimeline.cps
    static let typeStep = 1.0 / 12
    static let fastStep = 1.0 / 24
    static let glanceStep = 1.0 / 6
    static let blinkLen = 0.3
    static let glanceLen = 1.0

    static func u(_ o: SceneOptions, _ salt: Int) -> Double { TickNoise.unit(o.seed, salt) }

    /// Начало ухода: после злорадства или когда досмотрела.
    public static func leaveStart(_ w: SceneWatch) -> Double {
        if let g = w.ghostAt { return max(arrive, g + RigMoments.ghostLen) }
        return max(arrive, w.gloatAt.map { min($0, w.end) + gloatLen } ?? w.end)
    }

    public static func duration(_ w: SceneWatch) -> Double { leaveStart(w) + leaveLen }

    public static func calm(_ w: SceneWatch) -> Range<Double> { arrive..<leaveStart(w) }

    /// Когда пузырь реплики `k` виден: проступает за 0,1 с до печати, держится `hold` после неё (или до следующей).
    static func span(_ k: Int, _ w: SceneWatch) -> (start: Double, typed: Double, end: Double) {
        let s = w.says[k]
        let typed = s.at + Double(s.chars) / cps
        var end = typed + hold
        if k + 1 < w.says.count { end = min(end, w.says[k + 1].at - 0.15) }
        end = min(end, leaveStart(w))
        return (s.at - 0.1, typed, max(s.at, end))
    }

    // MARK: события покоя

    static func blinks(_ w: SceneWatch, _ o: SceneOptions) -> [Double] {
        events(from: arrive + 1.9 + 0.8 * u(o, 971), to: w.gloatAt ?? leaveStart(w), len: blinkLen, gap: 2.3, spread: 0.9, salt: 972, o)
    }

    static func glances(_ w: SceneWatch, _ o: SceneOptions) -> [Double] {
        events(from: arrive + 3.2 + 1.0 * u(o, 973), to: w.gloatAt ?? leaveStart(w), len: glanceLen, gap: 4.5, spread: 2.0, salt: 974, o)
    }

    static func glitches(_ w: SceneWatch, _ o: SceneOptions) -> [Double] {
        events(from: arrive + 2.6 + u(o, 975), to: w.gloatAt ?? leaveStart(w), len: 0.1, gap: 3.4, spread: 1.6, salt: 976, o)
    }

    static func events(from: Double, to end: Double, len: Double, gap: Double, spread: Double, salt: Int, _ o: SceneOptions) -> [Double] {
        var out: [Double] = []
        var t = from
        var k = 0
        while t + len < end, out.count < 400 {
            out.append(t)
            k += 1
            t += gap + spread * TickNoise.unit(k, salt + o.seed)
        }
        return out
    }

    static func lookTime(_ t: Double, _ w: SceneWatch, _ o: SceneOptions) -> Double {
        glances(w, o).reduce(0) { acc, g in acc + min(glanceLen, max(0, t - g)) }
    }

    // MARK: кадр

    public static func frame(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions, _ w: SceneWatch) -> SceneFrame {
        let leave = leaveStart(w)
        let smearEnd = smearStart + smearLen
        switch t {
        case ..<0.25: return SceneTimeline.out("out", at: g.home, t, len: 0.25, c)
        case ..<smearStart:
            return SceneTimeline.jump("jump", from: g.home, to: g.target, t - 0.25, len: smearStart - 0.25)
        case ..<smearEnd:
            var f = SceneFrame(phase: "smear", eyes: nil)
            f.smear = Transitions.windowSmear(w.window, progress: CGFloat((t - smearStart) / smearLen), seed: o.seed, under: g.target.midX)
            return f
        case ..<arrive:
            var f = SceneTimeline.into("climb", at: g.target, t - smearEnd, len: climbLen, c)
            // Хвост размаза ещё стекает за край, пока она вылезает.
            f.smear = nil
            f.rig = RigMoments.base(o, t: t)
            return f
        case ..<leave: return sit(t, g, c, o, w)
        case ..<(leave + 0.3):
            // Призрак уже рассыпался — уходить нечему, только молния домой.
            if w.ghostAt != nil { return SceneFrame(phase: "leave", eyes: nil) }
            var f = SceneTimeline.out("leave", at: SceneTimeline.lean(g.target, g), t - leave, len: 0.3, c)
            f.rig = RigMoments.base(o, t: t)
            return f
        case ..<(leave + 0.45):
            return SceneTimeline.jump("back", from: SceneTimeline.lean(g.target, g), to: g.home, t - leave - 0.3, len: 0.15)
        default:
            var f = SceneTimeline.into("home", at: g.home, t - leave - 0.45, len: leaveLen - 0.45, c)
            f.glitch = 2
            return f
        }
    }

    static func sit(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions, _ w: SceneWatch) -> SceneFrame {
        var eyes = SceneTimeline.lean(g.target, g)
        let gloat = w.gloatAt.map { t >= $0 } ?? false
        var f = SceneFrame(phase: gloat ? "gloat" : "watch", eyes: eyes)
        f.clip = SceneClip.look
        f.clipT = lookTime(t, w, o)
        let speaking = w.says.indices.first { k in
            let s = span(k, w)
            return t >= s.start && t < s.end + 0.15
        }
        if let k = speaking {
            let s = span(k, w)
            if t >= w.says[k].at, t < s.typed, c.contains(SceneClip.talk), !gloat {
                f.clip = SceneClip.talk; f.clipT = t - w.says[k].at
            }
            if let r = g.bubble {
                let chars = w.says[k].chars
                let n = min(chars, max(0, Int((t - w.says[k].at) * cps)))
                let caret = n < chars || Int(t * 2.5) % 2 == 0
                f.bubble = SceneBubble(rect: r, typed: n, caret: caret, glitch: t < w.says[k].at || t >= s.end, say: k)
                if t >= s.typed, t < s.typed + 0.1 { f.glitch = max(f.glitch, 1) }
            }
        }
        if !gloat, c.contains(SceneClip.close), let b = blinks(w, o).first(where: { t >= $0 && t < $0 + blinkLen }) {
            f.clip = SceneClip.close; f.clipT = t - b; f.loop = false
        }
        if !gloat, let k = glitches(w, o).firstIndex(where: { t >= $0 && t < $0 + 2.0 / 24 }) {
            f.glitch = max(f.glitch, TickNoise.unit(k, 977 + o.seed) < 0.3 ? 2 : 1)
        }
        if gloat, let at = w.gloatAt {
            // Злорадство: прищур (`slits`, иначе полузакрытые), дрожь 12 раз в секунду, глитч через кадр.
            let tick = Int((t - at) * 12)
            if c.contains(SceneClip.slits) { f.clip = SceneClip.slits; f.clipT = t - at; f.loop = false }
            else { f.clip = SceneClip.close; f.clipT = 0.12; f.loop = false }
            let dx = (CGFloat(TickNoise.unit(tick, 978 + o.seed)) - 0.5) * 6
            let dy = (CGFloat(TickNoise.unit(tick, 979 + o.seed)) - 0.5) * 3
            eyes = eyes.offsetBy(dx: dx, dy: dy)
            f.eyes = eyes
            f.glitch = max(f.glitch, tick % 3 == 0 ? 2 : 1)
            f.squash = 0.92
        }
        // Мини-маска: смотрит в терминал, показывает пальцем, засыпает, злорадствует, рассыпается призраком.
        let look = gloat ? nil : glances(w, o).first { t >= $0 && t < $0 + glanceLen }.map { (t - $0) / glanceLen }
        let blink = gloat ? nil : blinks(w, o).first { t >= $0 && t < $0 + blinkLen }.map { 1 - abs(2 * (t - $0) / blinkLen - 1) }
        f.rig = RigMoments.watch(t, g, o, w, look: look, blink: blink, speaking: speaking)
        if RigMoments.sleepStart(t, w) != nil { f.phase = "sleep" }
        if let at = w.ghostAt, t >= at {
            f.phase = "ghost"
            f.bubble = nil
            f.eyes = SceneTimeline.lean(g.target, g)
            f.squash = 1
            f.glitch = 0
        }
        if o.perchHold {
            f.glitch = max(f.glitch, 1)
            f.squash = 0.9
        }
        // Окно сдвинули — мини-прыжок (как у посадки).
        if let h = o.hopAt, let from = o.hopFrom, t >= h, t < h + PerchTimeline.hopLen {
            let p = CGFloat((t - h) / PerchTimeline.hopLen)
            let e = p * p * (3 - 2 * p)
            f.phase = "hop"
            f.eyes = CGRect(x: from.minX + (eyes.minX - from.minX) * e, y: from.minY + (eyes.minY - from.minY) * e,
                            width: eyes.width, height: eyes.height)
            f.squash = 0.8 + 0.2 * abs(1 - 2 * p)
            f.glitch = 2
            f.bubble = nil
            f.rig?.set(.none)
        }
        return f
    }

    // MARK: расписание кадров

    /// Следующее изменение кадра после `t`: вне покоя — 24 fps; в покое — по событию (печать, моргание, «косится»,
    /// глитч, прыжок), злорадство — 12 fps.
    public static func nextChange(after t: Double, _ o: SceneOptions, _ w: SceneWatch) -> Double {
        let calm = calm(w)
        guard calm.contains(t) else { return t + fastStep }
        var spans: [(Double, Double, Double)] = []
        for k in w.says.indices {
            let s = span(k, w)
            spans.append((s.start, w.says[k].at, fastStep))
            spans.append((w.says[k].at, s.typed, typeStep))
            spans.append((s.typed, s.typed + 0.1, fastStep))
            spans.append((s.end, s.end + 0.15, fastStep))
            // Каретка мигает, пока пузырь стоит.
            if t >= s.typed, t < s.end { spans.append((t, min(s.end, (floor(t * 2.5) + 1) / 2.5), 1)) }
        }
        spans += blinks(w, o).map { ($0, $0 + blinkLen, typeStep) }
        spans += glances(w, o).map { ($0, $0 + glanceLen, glanceStep) }
        spans += glitches(w, o).map { ($0, $0 + 2.0 / 24, fastStep) }
        if let g = w.gloatAt { spans.append((g, leaveStart(w), 1.0 / 12)) }
        if let h = o.hopAt { spans.append((h, h + PerchTimeline.hopLen, fastStep)) }
        // Риг: палец в терминал (убирается после печати), сон (веки — 6 fps, «z» — 4 fps), призрак — 12 fps.
        for k in w.says.indices {
            let s = span(k, w)
            spans.append((s.typed, s.typed + 0.6, typeStep))
        }
        for (a, b) in RigMoments.sleepWindows(w) {
            spans.append((a, min(b, a + RigMoments.sleepFall), 1.0 / 6))
            if b > a + RigMoments.sleepFall { spans.append((a + RigMoments.sleepFall, b, 0.25)) }
        }
        if let g = w.ghostAt { spans.append((g, leaveStart(w), 1.0 / 12)) }
        var next = calm.upperBound
        if o.perchHold { next = min(next, t + typeStep) }
        for (a, b, step) in spans {
            if t >= a - 1e-6, t < b { next = min(next, t + step, b) }
            if a > t + 1e-6 { next = min(next, a) }
            if b > t + 1e-6 { next = min(next, b) }
        }
        return next + 0.0005
    }

    /// Шаг до следующего кадра (не больше 1 с — удержание и обрыв подхватываются).
    public static func step(_ t: Double, _ o: SceneOptions, _ w: SceneWatch) -> Double {
        // Не меньше 5 мс: граница события (начало реплики, моргания) не перескакивается шагом 1/24.
        min(1, max(0.005, nextChange(after: t, o, w) - t))
    }
}
