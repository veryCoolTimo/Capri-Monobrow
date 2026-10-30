import SwiftUI
import CapriKit

/// Эффекты поверх глаз Capri, нарисованные кодом: глитч (сдвинутые полосы и разнос по цвету, как «relic» в
/// сериале) и её тонкие малиновые молнии-зигзаги со звёздочками (по рефу Тимофея) и фиолетовой «сбитой печатью».
/// Всё детерминировано по тику 12 fps.
enum CapriFX {
    /// Глитч по образцу сериала (маска с открытым ртом рассыпается): уровень 1 — сдвинутые полосы с цветным
    /// разносом; 2 — плюс кайма по краям фигур, рваный край кадра и цветные мазки (строка растянута в полосу);
    /// 3 — плюс сдвинутые блоки, цветные плашки и двойная экспозиция.
    struct Glitch {
        var level: Int
        /// Разнос малиновой и фиолетовой копий (доля ширины).
        var split: CGFloat
        /// Полосы: верх и высота (доли высоты), сдвиг (доля ширины).
        var slices: [(y: CGFloat, h: CGFloat, dx: CGFloat)] = []
        /// Мазки: полоса (доли высоты), строка-источник (доля высоты), цвет из `tints`.
        var smears: [(y: CGFloat, h: CGFloat, src: CGFloat, tint: Int)] = []
        /// Блоки: прямоугольник (доли кадра) и его сдвиг.
        var blocks: [(rect: CGRect, dx: CGFloat, dy: CGFloat)] = []
        /// Цветные плашки (доли кадра).
        var patches: [(rect: CGRect, tint: Int)] = []
        /// Зерно рваного края (0 — нет).
        var tear = 0
        /// Сдвиг двойной экспозиции (доля ширины, 0 — нет).
        var ghost: CGFloat = 0
    }

    static let tints: [Color] = [Palette.crimson, Palette.acid, Palette.violet, Color(red: 1, green: 0.48, blue: 0.66)]

    /// Уровень глитча из отладки (`fx N` в `--debug-control`), пока не истёк срок.
    nonisolated(unsafe) static var forced: (level: Int, until: Date)?

    struct Bolt {
        /// Зерно формы каждой молнии (одна или две).
        var seeds: [Int]
        /// «Кипение» линии: меняется раз в два тика.
        var boil: Int
    }

    /// Глитч в тике `tick` (`since` — тики с начала настроения): уровень по настроению; смена настроения —
    /// короткий переход уровня 2.
    static func glitch(_ mood: CapriMood, tick: Int, since: Int) -> Glitch? {
        if let f = forced, f.until > Date() { return make(level: f.level, tick: tick, strength: 1) }
        func on(_ period: Int, _ length: Int, _ salt: Int, _ t: Int? = nil) -> Bool {
            TickNoise.burst(t ?? tick, period: period, length: length, salt: salt) != nil
        }
        let level: Int
        switch mood {
        case .idle, .listening:
            level = on(240, 4, 9) ? 3 : on(66, 2, 1) ? (TickNoise.unit(tick / 66, 13) < 0.35 ? 2 : 1) : 0
        case .thinking: level = on(40, 2, 2) ? 1 : 0
        case .speaking: level = on(36, 3, 7) ? 2 : on(9, 1, 3) ? 1 : 0
        case .alert: level = on(36, 4, 4, since) ? 3 : on(12, 1, 8) ? 1 : 0
        case .error: level = on(20, 3, 5) ? 3 : on(7, 1, 10) ? 2 : 0
        }
        let transition = since > 0 && since < 3 ? 2 : 0
        let l = max(level, transition)
        return l > 0 ? make(level: l, tick: tick, strength: mood == .error ? 1.5 : 1) : nil
    }

    /// Рисунок глитча уровня `level` для тика: каждый тик — новый.
    static func make(level: Int, tick: Int, strength: CGFloat) -> Glitch {
        let u = { (salt: Int) in CGFloat(TickNoise.unit(tick, salt)) }
        var g = Glitch(level: level, split: (0.012 + 0.018 * u(12)) * strength)
        g.slices = (0..<(2 + Int(TickNoise.hash(tick, 11) % 3) + level)).map { k in
            let dx = (0.03 + 0.07 * u(22 + k * 3)) * (u(23 + k * 3) < 0.5 ? -1 : 1) * strength
            return (y: u(20 + k * 3) * 0.9, h: 0.03 + 0.12 * u(21 + k * 3), dx: dx)
        }
        guard level >= 2 else { return g }
        g.tear = tick | 1
        g.smears = (0..<(1 + level)).map { k in
            (y: u(200 + k * 4) * 0.9, h: 0.02 + 0.1 * u(201 + k * 4), src: u(202 + k * 4), tint: Int(TickNoise.hash(tick, 203 + k * 4) % 4))
        }
        guard level >= 3 else { return g }
        g.blocks = (0..<(3 + Int(TickNoise.hash(tick, 300) % 3))).map { k in
            let w = 0.1 + 0.25 * u(301 + k * 5), h = 0.06 + 0.18 * u(302 + k * 5)
            return (rect: CGRect(x: u(303 + k * 5) * (1 - w), y: u(304 + k * 5) * (1 - h), width: w, height: h),
                    dx: (u(305 + k * 5) - 0.5) * 0.2, dy: (u(306 + k * 5) - 0.5) * 0.1)
        }
        g.patches = (0..<(1 + Int(TickNoise.hash(tick, 400) % 3))).map { k in
            let w = 0.08 + 0.3 * u(401 + k * 4), h = 0.04 + 0.2 * u(402 + k * 4)
            return (rect: CGRect(x: u(403 + k * 4) * (1 - w), y: u(404 + k * 4) * (1 - h), width: w, height: h),
                    tint: Int(TickNoise.hash(tick, 405 + k * 4) % 4))
        }
        g.ghost = (0.05 + 0.08 * u(500)) * (u(501) < 0.5 ? -1 : 1)
        return g
    }

    /// Молния в тике `tick`: держится несколько рисунков (в покое и при ошибке — вместе с глитчем).
    static func bolt(_ mood: CapriMood, tick: Int, since: Int) -> Bolt? {
        let beat: Int? = switch mood {
        case .idle, .listening: TickNoise.burst(tick, period: 66, length: 8, salt: 1)
        case .thinking: nil
        case .speaking: TickNoise.burst(tick, period: 24, length: 5, salt: 6)
        case .alert: TickNoise.burst(since, period: 36, length: 22, salt: 4)
        case .error: TickNoise.burst(tick, period: 20, length: 4, salt: 5)
        }
        guard let beat else { return nil }
        let two = mood == .alert || TickNoise.unit(beat, 32) < 0.4
        return Bolt(seeds: two ? [beat * 2, beat * 2 + 1] : [beat * 2], boil: tick / 2)
    }

    /// Вершины молнии в кадре `r`: из-за края поперёк кадра зигзагом из 5–7 колен.
    static func boltPoints(_ seed: Int, boil: Int, in r: CGRect) -> [CGPoint] {
        let u = { (salt: Int) in CGFloat(TickNoise.unit(seed, 80 + salt)) }
        let side = Int(TickNoise.hash(seed, 81) % 4)
        // Начало за краем и направление: слева/справа — поперёк, сверху/снизу — вниз/вверх наискось.
        let start: CGPoint, end: CGPoint
        switch side {
        case 0: start = CGPoint(x: -0.03, y: 0.15 + 0.7 * u(1)); end = CGPoint(x: 0.35 + 0.3 * u(2), y: 0.2 + 0.6 * u(3))
        case 1: start = CGPoint(x: 1.03, y: 0.15 + 0.7 * u(1)); end = CGPoint(x: 0.35 + 0.3 * u(2), y: 0.2 + 0.6 * u(3))
        case 2: start = CGPoint(x: 0.1 + 0.8 * u(1), y: -0.05); end = CGPoint(x: 0.2 + 0.6 * u(2), y: 0.85)
        default: start = CGPoint(x: 0.1 + 0.8 * u(1), y: 1.05); end = CGPoint(x: 0.2 + 0.6 * u(2), y: 0.15)
        }
        let a = CGPoint(x: r.minX + start.x * r.width, y: r.minY + start.y * r.height)
        let b = CGPoint(x: r.minX + end.x * r.width, y: r.minY + end.y * r.height)
        let dx = b.x - a.x, dy = b.y - a.y, len = max(1, (dx * dx + dy * dy).squareRoot())
        let nx = -dy / len, ny = dx / len
        let n = 5 + Int(TickNoise.hash(seed, 82) % 3)
        return (0..<n).map { k in
            let f = CGFloat(k) / CGFloat(n - 1)
            // Колено вбок, поочерёдно; кипение — лёгкий сдвиг раз в два тика.
            let side = k == 0 || k == n - 1 ? 0 : (k % 2 == 0 ? 1 : -1) * (0.6 + 0.4 * u(10 + k))
            let amp = r.height * 0.13 * side + r.height * 0.012 * (CGFloat(TickNoise.unit(boil, 90 + k)) - 0.5)
            return CGPoint(x: a.x + dx * f + nx * amp, y: a.y + dy * f + ny * amp)
        }
    }

    /// Контур молнии: каждое колено — тонкая игла от широкого основания к острию чуть дальше следующей вершины.
    static func boltPath(_ seed: Int, boil: Int, in r: CGRect) -> Path {
        let pts = boltPoints(seed, boil: boil, in: r)
        var path = Path()
        for k in 0..<(pts.count - 1) {
            let p = pts[k], q = pts[k + 1]
            let dx = q.x - p.x, dy = q.y - p.y, len = max(1, (dx * dx + dy * dy).squareRoot())
            let w = r.height * 0.045 * (1 - 0.5 * CGFloat(k) / CGFloat(pts.count))
            let tip = CGPoint(x: q.x + dx * 0.12, y: q.y + dy * 0.12)
            path.addLines([CGPoint(x: p.x - dy / len * w / 2, y: p.y + dx / len * w / 2), tip,
                           CGPoint(x: p.x + dy / len * w / 2, y: p.y - dx / len * w / 2)])
            path.closeSubpath()
        }
        return path
    }

    /// Звёздочки-контуры рядом с молнией, как на рефе.
    static func stars(_ seed: Int, near pts: [CGPoint], in r: CGRect) -> Path {
        var path = Path()
        for k in 0..<2 {
            let p = pts[1 + Int(TickNoise.hash(seed, 100 + k) % UInt64(max(1, pts.count - 2)))]
            let c = CGPoint(x: p.x + r.height * (0.25 * CGFloat(TickNoise.unit(seed, 110 + k)) - 0.12),
                            y: p.y + r.height * (0.25 * CGFloat(TickNoise.unit(seed, 120 + k)) - 0.12))
            let R = r.height * (0.035 + 0.02 * CGFloat(TickNoise.unit(seed, 130 + k)))
            let star = (0..<10).map { i -> CGPoint in
                let a = CGFloat(i) * .pi / 5 - .pi / 2, rad = i % 2 == 0 ? R : R * 0.45
                return CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad)
            }
            path.addLines(star)
            path.closeSubpath()
        }
        return path
    }
}

/// Кадр глаз с эффектами: рисунок вписан 2:1, поверх — глитч и молнии (обрезаны по кадру).
struct CapriShotView: View {
    var image: NSImage?
    var glitch: CapriFX.Glitch?
    var bolt: CapriFX.Bolt?

    var body: some View {
        Canvas { ctx, size in
            guard let image, image.size.height > 0 else { return }
            let aspect = image.size.width / image.size.height
            let w = min(size.width, size.height * aspect), h = w / aspect
            let r = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
            let art = ctx.resolve(Image(nsImage: image).resizable().interpolation(.high))
            ctx.clip(to: Path(r))
            ctx.draw(art, in: r)
            if let glitch { draw(glitch, art: art, in: r, ctx: ctx) }
            if let bolt { draw(bolt, in: r, ctx: ctx) }
        }
    }

    /// Глитч: двойная экспозиция → кайма → мазки → сдвинутые полосы с цветным разносом → блоки → плашки → рваный край.
    private func draw(_ g: CapriFX.Glitch, art: GraphicsContext.ResolvedImage, in r: CGRect, ctx: GraphicsContext) {
        func band(_ y: CGFloat, _ h: CGFloat) -> Path {
            Path(CGRect(x: r.minX, y: r.minY + y * r.height, width: r.width, height: h * r.height))
        }
        if g.ghost != 0 {
            var c = ctx
            c.opacity = 0.32
            c.draw(art, in: r.offsetBy(dx: g.ghost * r.width, dy: 0))
        }
        if g.level >= 2 {
            // Кайма: тонированные копии вразнос, «светлее» не выбеливает зелёный, но даёт цветной край у тёмного.
            for (color, dx) in [(Palette.violet, -g.split), (Palette.crimson, g.split)] {
                var c = ctx
                c.blendMode = .lighten
                c.addFilter(.colorMultiply(color))
                c.draw(art, in: r.offsetBy(dx: dx * r.width * 0.6, dy: 0))
            }
        }
        for m in g.smears {
            // Строка `src` растянута на всю полосу — горизонтальный мазок, сверху — цвет.
            var c = ctx
            c.clip(to: band(m.y, m.h))
            let k = max(1, m.h / 0.006)
            c.draw(art, in: CGRect(x: r.minX, y: r.minY + m.y * r.height - m.src * r.height * k,
                                   width: r.width, height: r.height * k))
            c.blendMode = .screen
            c.fill(band(m.y, m.h), with: .color(CapriFX.tints[m.tint].opacity(0.45)))
        }
        for s in g.slices {
            var c = ctx
            c.clip(to: band(s.y, s.h))
            let shifted = r.offsetBy(dx: s.dx * r.width, dy: 0)
            c.draw(art, in: shifted)
            for (color, dx) in [(Palette.crimson, g.split), (Palette.violet, -g.split)] {
                var t = c
                t.blendMode = .screen
                t.opacity = 0.8
                t.addFilter(.colorMultiply(color))
                t.draw(art, in: shifted.offsetBy(dx: dx * r.width, dy: 0))
            }
        }
        for b in g.blocks {
            var c = ctx
            let rect = CGRect(x: r.minX + b.rect.minX * r.width, y: r.minY + b.rect.minY * r.height,
                              width: b.rect.width * r.width, height: b.rect.height * r.height)
            c.clip(to: Path(rect))
            c.draw(art, in: r.offsetBy(dx: b.dx * r.width, dy: b.dy * r.height))
        }
        for p in g.patches {
            var c = ctx
            c.blendMode = .screen
            c.fill(Path(CGRect(x: r.minX + p.rect.minX * r.width, y: r.minY + p.rect.minY * r.height,
                               width: p.rect.width * r.width, height: p.rect.height * r.height)),
                   with: .color(CapriFX.tints[p.tint].opacity(0.6)))
        }
        if g.tear != 0 {
            // Рваный край: короткие белые и чёрные штрихи по левому и правому краю.
            var white = Path(), black = Path()
            for k in 0..<18 {
                let y = r.minY + r.height * TickNoise.unit(g.tear, 600 + k)
                let w = r.width * (0.01 + 0.06 * TickNoise.unit(g.tear, 620 + k))
                let h = max(1, r.height * 0.008 * (1 + TickNoise.unit(g.tear, 640 + k)))
                let x = k % 2 == 0 ? r.minX : r.maxX - w
                if TickNoise.unit(g.tear, 660 + k) < 0.5 { white.addRect(CGRect(x: x, y: y, width: w, height: h)) }
                else { black.addRect(CGRect(x: x, y: y, width: w, height: h)) }
            }
            ctx.fill(white, with: .color(.white.opacity(0.8)))
            ctx.fill(black, with: .color(.black))
        }
    }

    private func draw(_ b: CapriFX.Bolt, in r: CGRect, ctx: GraphicsContext) {
        for seed in b.seeds {
            let path = CapriFX.boltPath(seed, boil: b.boil, in: r)
            // Фиолетовая «сбитая печать» под молнией, сама молния — малиновая, рядом звёздочки-контуры.
            ctx.fill(path.offsetBy(dx: r.height * 0.012, dy: r.height * 0.015), with: .color(Palette.violet))
            ctx.fill(path, with: .color(Palette.crimson))
            let stars = CapriFX.stars(seed, near: CapriFX.boltPoints(seed, boil: b.boil, in: r), in: r)
            ctx.stroke(stars, with: .color(Palette.crimson), lineWidth: max(1, r.height * 0.008))
        }
    }
}
