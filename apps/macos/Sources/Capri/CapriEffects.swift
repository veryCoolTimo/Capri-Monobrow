import SwiftUI
import CapriKit

/// Эффекты поверх глаз Capri, нарисованные кодом: глитч (сдвинутые полосы и разнос по цвету, как «relic» в
/// сериале) и её тонкие малиновые молнии-зигзаги со звёздочками (по рефу Тимофея) и фиолетовой «сбитой печатью».
/// Всё детерминировано по тику 12 fps.
enum CapriFX {
    struct Glitch {
        /// Разнос малиновой и фиолетовой копий (доля ширины).
        var split: CGFloat
        /// Полосы: верх и высота (доли высоты), сдвиг (доля ширины).
        var slices: [(y: CGFloat, h: CGFloat, dx: CGFloat)]
    }

    struct Bolt {
        /// Зерно формы каждой молнии (одна или две).
        var seeds: [Int]
        /// «Кипение» линии: меняется раз в два тика.
        var boil: Int
    }

    /// Глитч в тике `tick` (`since` — тики с начала настроения).
    static func glitch(_ mood: CapriMood, tick: Int, since: Int) -> Glitch? {
        let beat: Int? = switch mood {
        case .idle, .listening: TickNoise.burst(tick, period: 66, length: 2, salt: 1)
        case .thinking: TickNoise.burst(tick, period: 40, length: 2, salt: 2)
        case .speaking: TickNoise.burst(tick, period: 9, length: 1, salt: 3)
        case .alert: TickNoise.burst(since, period: 36, length: 3, salt: 4)
        case .error: TickNoise.burst(tick, period: 20, length: 3, salt: 5)
        }
        guard beat != nil else { return nil }
        let strength: CGFloat = mood == .error ? 1.6 : 1
        let count = 2 + Int(TickNoise.hash(tick, 11) % 3)
        let slices = (0..<count).map { k -> (y: CGFloat, h: CGFloat, dx: CGFloat) in
            let u = { (salt: Int) in CGFloat(TickNoise.unit(tick, 20 + k * 3 + salt)) }
            let dx = (0.03 + 0.07 * u(2)) * (u(3) < 0.5 ? -1 : 1) * strength
            return (y: u(0) * 0.9, h: 0.04 + 0.14 * u(1), dx: dx)
        }
        return Glitch(split: (0.012 + 0.018 * CGFloat(TickNoise.unit(tick, 12))) * strength, slices: slices)
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

    /// Глитч: полосы кадра сдвинуты, в каждой — малиновая и фиолетовая копии вразнос (цвет только в полосах).
    private func draw(_ g: CapriFX.Glitch, art: GraphicsContext.ResolvedImage, in r: CGRect, ctx: GraphicsContext) {
        for s in g.slices {
            var c = ctx
            c.clip(to: Path(CGRect(x: r.minX, y: r.minY + s.y * r.height, width: r.width, height: s.h * r.height)))
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
