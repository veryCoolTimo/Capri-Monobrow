import SwiftUI
import AppKit

/// Capri (Project Capricorn, «Cyberpunk: Edgerunners 2») — своя векторная реконструкция по рефам, нарисованная
/// кодом. Приёмы из capri-desktop (только как образец, код не копировался):
/// перерисовка «на двойках» (12 рисунков в секунду) с лёгким «кипением» линии, позы без твинов, фиолетовый
/// сдвинутый контур под каждой формой, глитч со сдвигом слоёв при смене настроения, «много глаз», когда тебя ждут.
/// Единицы: 27 — расстояние между глазами; центр головы — (0, 0), y вниз.
enum CapriMood: Equatable {
    /// Ничего не происходит: моргает, переводит взгляд, грива парит.
    case idle
    /// Поле ввода в фокусе: глаза шире, смотрит вниз на поле, ухмылка.
    case listening
    /// Ждём ответ Codex: прищур, взгляд мечется вверх, голова качается.
    case thinking
    /// Идёт ответ: открытый белый «клык» шевелится по слогам.
    case speaking
    /// Кто-то ждёт тебя: по маске расцветают глаза, грива дыбом, оскал.
    case alert
    /// Ошибка: пустые глаза, рот вниз, глитч.
    case error
}

private enum Ink {
    static let hair = Color(hex: 0xF2154C)
    static let hairDeep = Color(hex: 0xC80F3F)
    static let violet = Color(hex: 0x8A3DFF)
    static let ink = Color(hex: 0x0A0710)
    static let mask = Color(hex: 0x22F27A)
    static let iris = Color(hex: 0x1D6CFF)
    static let white = Color.white
    static let sparkle = Color(hex: 0xFFE6EE)
    static let mouthInner = Color(hex: 0x2A0F3A)
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Поза в один рисунок. Между настроениями — ступенчатый переход (тоже на двойках).
struct CapriPose {
    var blinkL = 0.0, blinkR = 0.0
    var gazeX = 0.0, gazeY = 0.0
    var squint = 0.0, eyeWide = 0.0
    var mouthOpen = 0.0, mouthSmile = 0.2
    var blankEyes = 0.0, manyEyes = 0.0, maskGlow = 0.0
    var tilt = 0.0          // радианы, вокруг шеи
    var bob = 0.0           // единицы, минус — вверх
    var flare = 0.0         // 0…1 — грива дыбом
    var split = 0.0         // 0…1 — RGB-сдвиг слоёв
    var slices = 0.0        // 0…1 — сдвиг горизонтальных полос

    static func lerp(_ a: CapriPose, _ b: CapriPose, _ t: Double) -> CapriPose {
        func m(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var o = b
        o.blinkL = m(a.blinkL, b.blinkL); o.blinkR = m(a.blinkR, b.blinkR)
        o.gazeX = m(a.gazeX, b.gazeX); o.gazeY = m(a.gazeY, b.gazeY)
        o.squint = m(a.squint, b.squint); o.eyeWide = m(a.eyeWide, b.eyeWide)
        o.mouthOpen = m(a.mouthOpen, b.mouthOpen); o.mouthSmile = m(a.mouthSmile, b.mouthSmile)
        o.blankEyes = t < 0.5 ? a.blankEyes : b.blankEyes
        o.manyEyes = m(a.manyEyes, b.manyEyes); o.maskGlow = m(a.maskGlow, b.maskGlow)
        o.tilt = m(a.tilt, b.tilt); o.bob = m(a.bob, b.bob); o.flare = m(a.flare, b.flare)
        return o
    }

    /// Рисунок настроения: `n` — номер рисунка (12 в секунду), `since` — секунды с начала настроения.
    /// `still` — «Уменьшить движение»: одна поза, без моргания и движения.
    static func at(_ mood: CapriMood, drawing n: Int, since: Double, still: Bool) -> CapriPose {
        var p = CapriPose()
        // Моргание: полузакрыт, закрыт, полузакрыт — три рисунка раз в `cycle` рисунков.
        func blink(_ cycle: Int) -> Double {
            guard !still else { return 0 }
            switch n % cycle { case 0, 2: return 0.55; case 1: return 1; default: return 0 }
        }
        // Плавание: четыре рисунка, каждый держится 6 кадров (как у capri-desktop — не синусоида).
        let float = still ? 0 : [0, -0.8, -1.6, -0.8][(n / 6) % 4]
        switch mood {
        case .idle:
            let b = blink(52)
            p.blinkL = b; p.blinkR = b
            // Взгляд — позы, удерживаемые ~3 с.
            let looks: [(Double, Double, Double)] = [(0, 0, 0), (0.55, 0.1, 0.05), (0, 0, 0), (-0.5, -0.25, -0.05)]
            let l = still ? looks[0] : looks[(n / 36) % looks.count]
            p.gazeX = l.0; p.gazeY = l.1; p.tilt = l.2
            p.bob = float
        case .listening:
            let b = blink(62)
            p.blinkL = b; p.blinkR = b
            p.eyeWide = 0.45; p.gazeX = 0.25; p.gazeY = 0.7
            p.mouthSmile = 0.75
            p.tilt = 0.09
            p.bob = float * 0.5
        case .thinking:
            p.squint = 0.55
            let side = still ? 0 : ((n / 9) % 2 == 0 ? 1.0 : -1.0)
            p.gazeX = 0.6 * side; p.gazeY = -0.7
            p.tilt = -0.06 * side
            p.mouthSmile = -0.1
            p.flare = 0.2
            p.bob = float
        case .speaking:
            let b = blink(46)
            p.blinkL = b; p.blinkR = b
            // Слоги: каждый рисунок держится два кадра (6 слогов в секунду).
            let syl: [Double] = [0.25, 0.85, 0.45, 1, 0.3, 0.7, 0.1, 0.9]
            p.mouthOpen = still ? 0.4 : syl[(n / 2) % syl.count]
            p.mouthSmile = 0.45
            p.tilt = still ? 0 : [0.04, 0.06, 0.03, 0.05][(n / 8) % 4]
            p.bob = still ? 0 : (n / 2) % 2 == 0 ? 0 : -0.5
        case .alert:
            p.eyeWide = 0.85
            p.manyEyes = still ? 1 : min(1, since / 0.9)
            p.maskGlow = still ? 0.8 : ((n / 6) % 2 == 0 ? 0.95 : 0.6)
            p.mouthSmile = 0.95; p.mouthOpen = 0.35
            p.gazeY = -0.6
            p.flare = 0.7
            // Подскок раз в ~2.2 с: вверх два рисунка, вниз.
            let hop = still ? 0 : [-3.5, -5, -3.5, -1][min(3, n % 26)]
            p.bob = n % 26 < 4 ? hop : float
        case .error:
            p.blankEyes = 1
            p.mouthSmile = -0.7
            p.tilt = -0.05
            let k = n % 20
            p.slices = still ? 0 : (k < 2 ? 1 : 0)
            p.split = still ? 0 : (k < 3 ? 0.8 : 0)
        }
        return p
    }
}

/// Вид Capri. `.bust` — грива, голова и плечи (помощник, чат); `.mask` — только маска с глазами (свёрнутый notch,
/// как её «чип» в capri-desktop). `active` — анимировать (виден и нужен); иначе статичный рисунок, CPU не тратится.
struct CapriFace: View {
    enum Style { case bust, mask }
    var mood: CapriMood
    var style: Style = .bust
    var active = true

    @State private var fromMood: CapriMood = .idle
    @State private var shownMood: CapriMood = .idle
    @State private var changedAt = Date.distantPast

    static let fps = 12.0
    /// Переход настроения: три рисунка (0.25 с), первые два — со сдвигом слоёв.
    private static let transition = 0.25
    private var still: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        Group {
            if style == .mask {
                // В свёрнутом notch: перерисовка только в рисунки моргания и после смены настроения.
                TimelineView(EyesSchedule(paused: !active || still)) { ctx in
                    canvas(ctx.date)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1 / Self.fps, paused: !active || still)) { ctx in canvas(ctx.date) }
            }
        }
        .onAppear { shownMood = mood; fromMood = mood }
        .onChange(of: mood) { m in
            fromMood = shownMood
            shownMood = m
            changedAt = Date()
        }
        .accessibilityLabel(Text("Capri"))
    }

    private func pose(_ date: Date) -> (CapriPose, Int) {
        let n = Int(date.timeIntervalSinceReferenceDate * Self.fps)
        if style == .mask {
            // Мини-маска: моргание по расписанию `EyesSchedule`, остальное — статично.
            var p = CapriPose.at(shownMood, drawing: 0, since: 10, still: true)
            if !still, let b = EyesSchedule.blink(at: date) { p.blinkL = b; p.blinkR = b }
            if shownMood == .alert { p.manyEyes = 0; p.eyeWide = 0.9 }
            return (p, n)
        }
        // На паузе (и при «Уменьшить движение») — сразу поза настроения, без кадров перехода.
        guard active, !still else { return (CapriPose.at(shownMood, drawing: n, since: 10, still: still), n) }
        let since = max(0, date.timeIntervalSince(changedAt))
        let target = CapriPose.at(shownMood, drawing: n, since: since, still: false)
        guard since < Self.transition else { return (target, n) }
        let from = CapriPose.at(fromMood, drawing: n, since: 10, still: false)
        var p = CapriPose.lerp(from, target, min(1, (since / Self.transition * 3).rounded(.down) / 3 + 1 / 3))
        if since < 2 / Self.fps { p.split = max(p.split, 1); p.slices = max(p.slices, 0.6) }
        return (p, n)
    }

    private func canvas(_ date: Date) -> some View {
        let (p, n) = pose(date)
        let boil = still ? 0 : n % 3
        return Canvas { ctx, size in
            if style == .mask { CapriDrawing.mask(&ctx, size: size, p) }
            else { CapriDrawing.bust(&ctx, size: size, p, boil: boil, drawing: n) }
        }
    }
}

// MARK: - Рисование

private typealias Poly = [CGPoint]
private func P(_ pts: [(Double, Double)]) -> Poly { pts.map { CGPoint(x: $0.0, y: $0.1) } }

private func path(_ poly: Poly, _ t: CGAffineTransform) -> Path {
    var p = Path()
    p.addLines(poly.map { $0.applying(t) })
    p.closeSubpath()
    return p
}

/// Детерминированный шум: одинаков для одного (i, seed) — «кипение» линии повторяется по трём рисункам.
private func noise(_ i: Int, _ seed: Int) -> Double {
    var x = UInt64(truncatingIfNeeded: i &* 73856093 ^ seed &* 19349663 ^ 0x9E3779B9)
    x ^= x >> 33; x = x &* 0xff51afd7ed558ccd; x ^= x >> 33
    return Double(x % 10_000) / 10_000 * 2 - 1
}

/// Capri крупным планом, как в рефах: чёрный клин головы, одна широкая зелёная полоса-маска, которую сверху
/// рассекает чёрный шип, круглые глаза-мишени, белый клык под маской, шипы-рога, за ней — плоская малиновая
/// грива с плотными блёстками. Единицы: кадр 100×100, центр лица — (0, 0), y вниз.
enum CapriDrawing {
    // Голова — чёрный клин, подбородок острый, чуть влево.
    private static let head = P([(-38, -16), (-18, -27), (16, -29), (40, -20), (42, -6), (30, 8), (12, 20), (-4, 33), (-12, 20), (-30, 6), (-40, -4)])
    /// Маска — одна широкая полоса со скошенными краями.
    private static let mask = P([(-33, -15), (-6, -18), (38, -21), (39, -6), (30, 5), (4, 6), (-24, 8), (-34, -1)])
    /// Чёрный шип, рассекающий маску сверху между глазами.
    private static let notch = P([(-8, -44), (7, -30), (2, 4)])
    /// Рога-шипы головы.
    private static let horns = [P([(2, -26), (36, -66), (16, -25)]), P([(-24, -24), (-34, -52), (-12, -27)]),
                                P([(36, -16), (66, -30), (40, -4)]), P([(-36, -8), (-58, -14), (-34, 2)])]
    /// Глаза: центр, радиус.
    private static let eyes: [(CGPoint, Double)] = [(CGPoint(x: -16, y: -5.5), 8.2), (CGPoint(x: 20, y: -8), 7.4)]
    /// Маленькие глаза, что расцветают по маске, когда тебя ждут: x, y, радиус, порог появления.
    private static let many: [(Double, Double, Double, Double)] = [
        (2, -1, 3.4, 0.05), (-28, 2, 2.6, 0.2), (32, -14, 2.8, 0.3), (-4, -14, 2.2, 0.4), (30, 1, 2.3, 0.5),
        (-26, -11, 2.0, 0.6), (10, 2, 1.8, 0.7), (12, -16, 1.8, 0.8),
    ]
    // Грива: плоские плиты за головой, уходят вверх и вправо, как в кадрах сериала.
    private static let maneSlabs = [
        P([(-60, -10), (-56, -60), (-20, -64), (20, -70), (64, -64), (66, -20), (58, 30), (-10, 20), (-58, 30)]),
        P([(10, -30), (70, -54), (68, -36), (40, -16)]),
        P([(30, -2), (74, -6), (72, 14), (40, 10)]),
        P([(-30, -20), (-70, -44), (-66, -26), (-40, -8)]),
        P([(-32, 4), (-72, 18), (-70, 40), (-44, 18)]),
        P([(22, 10), (60, 34), (54, 52), (30, 24)]),
    ]
    private static let maneCenter = CGPoint(x: 0, y: -8)
    /// Плечи — чёрные осколки с зелёной панелью слева и малиновой молнией справа.
    private static let shoulders = P([(-62, 60), (-50, 36), (-24, 26), (-6, 36), (14, 26), (40, 30), (62, 60)])
    private static let panelGreen = P([(-44, 38), (-30, 33), (-27, 44), (-41, 49)])
    private static let glyph = P([(20, 34), (31, 35), (26, 39), (34, 42), (23, 50), (26, 43), (19, 40)])

    /// Блёстки: фиксированные точки разного размера, по шести группам (одна группа гаснет по очереди — мерцание).
    /// Пути строятся один раз, в кадре — только преобразование.
    private static let glitter: [Path] = {
        var groups = Array(repeating: Path(), count: 6)
        for i in 0..<520 {
            let c = CGPoint(x: noise(i, 1) * 74, y: noise(i, 2) * 74 - 12)
            let r = i % 9 == 0 ? 0.9 + (noise(i, 3) + 1) * 0.4 : 0.25 + (noise(i, 3) + 1) * 0.2
            groups[i % 6].addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        return groups
    }()

    private static let bustBox = CGRect(x: -58, y: -64, width: 116, height: 116)

    /// Край кадра — осколок, а не квадрат (доли ширины/высоты холста).
    private static let frameShard = P([(0.08, 0.05), (0.62, 0), (0.97, 0.12), (1, 0.66), (0.86, 1), (0.1, 0.95), (0, 0.42)])

    /// `framed` — обрезать по осколку (в интерфейсе); значок заливает плашку целиком.
    static func bust(_ ctx: inout GraphicsContext, size: CGSize, _ p: CapriPose, boil: Int, drawing n: Int, framed: Bool = true) {
        if framed { ctx.clip(to: path(frameShard, CGAffineTransform(scaleX: size.width, y: size.height))) }
        let s = min(size.width / bustBox.width, size.height / bustBox.height)
        let base = CGAffineTransform(translationX: size.width / 2 - bustBox.midX * s, y: size.height / 2 - bustBox.midY * s)
            .scaledBy(x: s, y: s)
        if p.split > 0.01 {
            // «Другие разумы»: зелёная и малиновая копии, сдвинутые в стороны.
            for (dx, c) in [(-3.0, Ink.mask), (3.0, Ink.hair)] {
                var layer = ctx
                layer.opacity = 0.55 * p.split
                figure(&layer, base.translatedBy(x: dx * p.split, y: 0), s, p, boil: boil, drawing: n, flat: c)
            }
        }
        if p.slices > 0.01 {
            let bands = 4
            for b in 0..<bands {
                var band = ctx
                let h = size.height / Double(bands)
                band.clip(to: Path(CGRect(x: 0, y: Double(b) * h, width: size.width, height: h)))
                figure(&band, base.translatedBy(x: noise(b, n) * 5 * p.slices, y: 0), s, p, boil: boil, drawing: n, flat: nil)
            }
        } else {
            figure(&ctx, base, s, p, boil: boil, drawing: n, flat: nil)
        }
    }

    private static func figure(_ ctx: inout GraphicsContext, _ base: CGAffineTransform, _ s: Double, _ p: CapriPose,
                               boil: Int, drawing n: Int, flat: Color?) {
        let body = base.translatedBy(x: 0, y: p.bob * 0.3)
        let headT = base.translatedBy(x: 0, y: p.bob).translatedBy(x: 0, y: 30).rotated(by: p.tilt).translatedBy(x: 0, y: -30)
        func fill(_ poly: Poly, _ t: CGAffineTransform, _ c: Color) { ctx.fill(path(poly, t), with: .color(flat ?? c)) }
        func withViolet(_ poly: Poly, _ t: CGAffineTransform, _ c: Color) {
            if flat == nil { fill(poly, t.translatedBy(x: -1.4, y: 1.9), Ink.violet) }
            fill(poly, t, c)
        }
        // Грива: распушается от центра, края «кипят».
        let k = 1 + p.flare * 0.1
        func mane(_ poly: Poly, _ seed: Int) -> Poly {
            poly.enumerated().map { i, q in
                let dx = q.x - maneCenter.x, dy = q.y - maneCenter.y
                let j = flat == nil ? 0.7 + p.flare * 1.2 : 0
                return CGPoint(x: maneCenter.x + dx * k + noise(i + seed * 31, boil) * j, y: maneCenter.y + dy * k + noise(i + seed * 31, boil + 7) * j)
            }
        }
        let slabs = maneSlabs.enumerated().map { mane($1, $0) }
        for (i, slab) in slabs.enumerated() { withViolet(slab, headT, i == 0 ? Ink.hair : Ink.hairDeep) }
        if flat == nil {
            var clip = Path()
            for slab in slabs { clip.addPath(path(slab, headT)) }
            var g = ctx
            g.clip(to: clip)
            let spread = CGAffineTransform(translationX: maneCenter.x, y: maneCenter.y).scaledBy(x: k, y: k)
                .translatedBy(x: -maneCenter.x, y: -maneCenter.y).concatenating(headT)
            for (i, group) in glitter.enumerated() where i != (n / 2) % glitter.count {
                g.fill(group.applying(spread), with: .color(Ink.sparkle.opacity(0.92)))
            }
        }
        withViolet(shoulders, body, Ink.ink)
        fill(panelGreen, body, Ink.mask)
        fill(glyph, body, Ink.hair)
        for (i, h) in horns.enumerated() { withViolet(mane(h, 40 + i), headT, Ink.ink) }
        withViolet(head, headT, Ink.ink)
        if flat != nil { return }
        face(&ctx, headT, s, p)
    }

    /// Маска с глазами и шипом, рот — в системе головы `t`.
    private static func face(_ ctx: inout GraphicsContext, _ t: CGAffineTransform, _ s: Double, _ p: CapriPose, mouth withMouth: Bool = true) {
        let maskPath = path(mask, t)
        var glow = ctx
        if p.maskGlow > 0.35 { glow.addFilter(.shadow(color: Ink.mask, radius: max(1.5, (p.maskGlow - 0.35) * 8 * s))) }
        glow.fill(maskPath, with: .color(Ink.mask))
        var onMask = ctx
        onMask.clip(to: maskPath)
        for (c, r) in eyes { eye(&ctx, t, c, r * (1 + p.eyeWide * 0.12), s, p, blink: c.x < 0 ? p.blinkL : p.blinkR) }
        if p.manyEyes > 0.03 {
            var q = p
            q.squint = 0; q.blinkL = 0; q.blinkR = 0
            for (x, y, r, th) in many {
                let grow = min(1, max(0, (p.manyEyes - th) / 0.15))
                if grow > 0 { eye(&onMask, t, CGPoint(x: x, y: y), r * (0.5 + 0.5 * grow), s, q, blink: 0) }
            }
        }
        ctx.fill(path(notch, t), with: .color(Ink.ink))
        if withMouth { mouth(&ctx, t.translatedBy(x: 1, y: 11), s, p) }
    }

    /// Мини-маска для свёрнутого notch: полоса маски с глазами и шипом, без головы и рта.
    static func mask(_ ctx: inout GraphicsContext, size: CGSize, _ p: CapriPose) {
        let box = CGRect(x: -35, y: -25, width: 76, height: 34)
        let s = min(size.width / box.width, size.height / box.height)
        let t = CGAffineTransform(translationX: size.width / 2 - box.midX * s, y: size.height / 2 - box.midY * s).scaledBy(x: s, y: s)
        ctx.fill(path(mask, t.translatedBy(x: -1.6, y: 2.2)), with: .color(Ink.violet))
        face(&ctx, t, s, p, mouth: false)
    }

    /// Круглый глаз-мишень: чёрный обод с шипами, зелёное кольцо, синяя радужка, белый зрачок.
    /// Веко — зелёное, опускается сверху; закрытый глаз — дуга с крестиком, как в сериале.
    private static func eye(_ ctx: inout GraphicsContext, _ t: CGAffineTransform, _ c: CGPoint, _ r: Double, _ s: Double,
                            _ p: CapriPose, blink: Double) {
        let m = t.translatedBy(x: c.x, y: c.y)
        func circle(_ x: Double, _ y: Double, _ rr: Double) -> Path { Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: rr * 2, height: rr * 2)).applying(m) }
        let closed = min(1, max(0, blink))
        let lid = max(closed, min(1, max(0, p.squint)) * 0.5)
        if closed > 0.9 {
            var arc = Path()
            arc.move(to: CGPoint(x: -r, y: -r * 0.1))
            arc.addQuadCurve(to: CGPoint(x: r, y: -r * 0.1), control: CGPoint(x: 0, y: r * 0.7))
            arc.move(to: CGPoint(x: -r * 0.15, y: -r * 0.55)); arc.addLine(to: CGPoint(x: r * 0.15, y: r * 0.75))
            arc.move(to: CGPoint(x: r * 0.5, y: -r * 0.2)); arc.addLine(to: CGPoint(x: r * 0.15, y: r * 0.45))
            ctx.stroke(arc.applying(m), with: .color(Ink.ink), style: StrokeStyle(lineWidth: max(1, r * 0.22 * s), lineCap: .butt))
            return
        }
        // Шипы обода: два наружу-вверх, один вниз.
        let ink = GraphicsContext.Shading.color(Ink.ink)
        let side = c.x < 0 ? -1.0 : 1.0
        ctx.fill(path(P([(side * r * 0.5, -r * 0.8), (side * r * 1.25, -r * 1.35), (side * r * 0.95, -r * 0.3)]), m), with: ink)
        ctx.fill(path(P([(-side * r * 0.2, -r * 0.95), (-side * r * 0.35, -r * 1.5), (-side * r * 0.6, -r * 0.7)]), m), with: ink)
        ctx.fill(path(P([(side * r * 0.3, r * 0.9), (side * r * 0.9, r * 1.35), (side * r * 0.85, r * 0.45)]), m), with: ink)
        ctx.fill(circle(0, 0, r), with: ink)
        var inner = ctx
        inner.clip(to: circle(0, 0, r * 0.86))
        let gx = p.gazeX * r * 0.28, gy = p.gazeY * r * 0.28
        if p.blankEyes > 0.5 {
            inner.fill(circle(gx * 0.5, gy * 0.5, r * 0.78), with: .color(Ink.white))
            inner.stroke(circle(gx * 0.5, gy * 0.5, r * 0.78), with: .color(Ink.iris), lineWidth: max(0.6, r * 0.1 * s))
        } else {
            inner.stroke(circle(gx * 0.6, gy * 0.6, r * 0.72), with: .color(Ink.mask), lineWidth: max(0.6, r * 0.09 * s))
            inner.fill(circle(gx, gy, r * 0.56), with: .color(Ink.iris))
            inner.fill(circle(gx + r * 0.08, gy - r * 0.06, r * 0.24), with: .color(Ink.white))
        }
        if lid > 0.02 {
            // Веко: зелёное сверху с чёрной кромкой.
            let y = -r + 2 * r * lid
            inner.fill(Path(CGRect(x: -r, y: -r - 1, width: 2 * r, height: y + r + 1)).applying(m), with: .color(Ink.mask))
            var edge = Path()
            edge.move(to: CGPoint(x: -r, y: y)); edge.addLine(to: CGPoint(x: r, y: y - r * 0.1 * side))
            inner.stroke(edge.applying(m), with: ink, lineWidth: max(0.8, r * 0.18 * s))
        }
    }

    // MARK: рот

    /// Какой рот: тонкий зигзаг в покое, белый клык открытым, оскал с зубами — «тебя ждут».
    private enum MouthShape { case zigzag, fang, teeth }
    private static func mouthShape(_ p: CapriPose) -> MouthShape {
        if p.mouthOpen > 0.12 { return p.mouthSmile >= 0.85 && p.eyeWide >= 0.7 ? .teeth : .fang }
        return .zigzag
    }

    private static func mouth(_ ctx: inout GraphicsContext, _ t: CGAffineTransform, _ s: Double, _ p: CapriPose) {
        let white = GraphicsContext.Shading.color(Ink.white)
        switch mouthShape(p) {
        case .fang:
            // Белый клык: широкий верх с зазубриной посередине, острый низ, растёт с открытием.
            let o = min(1, max(0, p.mouthOpen))
            let w = 6 + o * 3, h = 6 + o * 8
            ctx.fill(path(P([(-w, -1), (-w * 0.3, 0), (0, -1.6), (w * 0.3, 0), (w, -1.8), (w * 0.2, h * 0.7), (-w * 0.1, h)]), t), with: white)
        case .teeth:
            // Оскал: щель полумесяцем, сверху и снизу острые зубы.
            let w = 15.0, d = 4 + p.mouthOpen * 6
            var slot = Path()
            slot.move(to: CGPoint(x: -w, y: -3))
            slot.addQuadCurve(to: CGPoint(x: w, y: -5), control: CGPoint(x: 0, y: -1))
            slot.addQuadCurve(to: CGPoint(x: -w, y: -3), control: CGPoint(x: 0, y: d * 2))
            let sp = slot.applying(t)
            ctx.fill(sp, with: .color(Ink.mouthInner))
            var teeth = ctx
            teeth.clip(to: sp)
            var tri = Path()
            let count = 7
            for i in 0..<count {
                let x0 = -w + 2 * w * Double(i) / Double(count), x1 = -w + 2 * w * Double(i + 1) / Double(count)
                tri.addLines([CGPoint(x: x0, y: -6), CGPoint(x: x1, y: -6), CGPoint(x: (x0 + x1) / 2, y: d * 0.7)]); tri.closeSubpath()
                tri.addLines([CGPoint(x: x0, y: d * 1.6), CGPoint(x: x1, y: d * 1.6), CGPoint(x: (x0 + x1) / 2, y: d * 0.45)]); tri.closeSubpath()
            }
            teeth.fill(tri.applying(t), with: white)
            ctx.stroke(sp, with: white, lineWidth: max(0.7, 0.7 * s))
        case .zigzag:
            // Тонкий белый зигзаг; уголок вверх — ухмылка, оба вниз — недовольство.
            let smile = min(1, max(-1, p.mouthSmile)), w = 6.0
            var z = Path()
            for i in 0...6 {
                let u = Double(i) / 6 * 2 - 1
                let y = (i % 2 == 0 ? -1.0 : 1.0) - smile * 2.2 * u * u + (smile > 0.5 ? -smile * 1.5 * max(0, u) : 0)
                let pt = CGPoint(x: u * w, y: y)
                if i == 0 { z.move(to: pt) } else { z.addLine(to: pt) }
            }
            ctx.stroke(z.applying(t), with: white, style: StrokeStyle(lineWidth: max(0.8, 1.1 * s), lineJoin: .miter))
        }
    }
}

/// Расписание перерисовки мини-маски: рисунки моргания (раз в
/// `blinkCycle` с). Между ними Canvas не перерисовывается — свёрнутый notch не тратит CPU. Даты строго растут.
struct EyesSchedule: TimelineSchedule {
    static let blinkCycle = 4.3
    static let frame = 1.0 / CapriFace.fps
    var paused: Bool

    /// Моргание в момент `date`: полузакрыт, закрыт, полузакрыт (по рисунку), иначе nil.
    static func blink(at date: Date) -> Double? {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: blinkCycle)
        switch Int(phase / frame) { case 0, 2: return 0.55; case 1: return 1; default: return nil }
    }

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var queue: [Date] = [start]
        var last = start
        var cycle = (start.timeIntervalSinceReferenceDate / Self.blinkCycle).rounded(.up)
        var k = 0
        return AnyIterator {
            if !queue.isEmpty {
                last = queue.removeFirst()
                return last
            }
            guard !paused else { return nil }
            // Моргание: три рисунка и рисунок «открыто», затем следующий цикл.
            while true {
                let date = Date(timeIntervalSinceReferenceDate: cycle * Self.blinkCycle + Double(k) * Self.frame + 0.001)
                k += 1
                if k > 3 { k = 0; cycle += 1 }
                if date > last { last = date; return date }
            }
        }
    }
}
