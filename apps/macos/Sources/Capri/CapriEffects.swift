import SwiftUI
import CapriKit

/// Эффекты поверх глаз Capri, нарисованные кодом: глитч (сдвинутые полосы и разнос по цвету, как «relic» в
/// сериале) и её малиновые молнии с блёстками и фиолетовой «сбитой печатью». Всё детерминировано по тику 12 fps.
enum CapriFX {
    struct Glitch {
        /// Разнос малиновой и фиолетовой копий (доля ширины).
        var split: CGFloat
        /// Полосы: верх и высота (доли высоты), сдвиг (доля ширины).
        var slices: [(y: CGFloat, h: CGFloat, dx: CGFloat)]
    }

    struct Bolt {
        /// Номера мест из `spots`.
        var shapes: [Int]
        var mirror: Bool
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
        let first = Int(TickNoise.hash(beat, 31) % UInt64(spots.count))
        let two = mood == .alert || TickNoise.unit(beat, 32) < 0.4
        return Bolt(shapes: two ? [first, (first + 2) % spots.count] : [first],
                    mirror: TickNoise.unit(beat, 33) < 0.5, boil: tick / 2)
    }

    /// Молния: классический клин-зигзаг в единичном квадрате (острие внизу).
    static let bolt: [CGPoint] = [
        CGPoint(x: 0.50, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.66, y: 0.40), CGPoint(x: 0.90, y: 0.40),
        CGPoint(x: 0.12, y: 1), CGPoint(x: 0.38, y: 0.54), CGPoint(x: 0.10, y: 0.54),
    ]

    /// Где молнии (доли кадра 2:1): между глаз и по краям, мимо зрачков; `up` — острием вверх.
    static let spots: [(box: CGRect, up: Bool)] = [
        (CGRect(x: 0.41, y: 0.42, width: 0.17, height: 0.70), true),
        (CGRect(x: 0.84, y: -0.12, width: 0.17, height: 0.62), false),
        (CGRect(x: -0.01, y: 0.50, width: 0.16, height: 0.62), true),
        (CGRect(x: 0.85, y: 0.55, width: 0.15, height: 0.56), true),
    ]

    /// Контур молнии `i` в кадре `r`; `mirror` — отражение по горизонтали, `boil` — кипение линии.
    static func boltPath(_ i: Int, mirror: Bool, boil: Int, in r: CGRect) -> Path {
        let spot = spots[i]
        let pts = bolt.enumerated().map { k, p -> CGPoint in
            let jx = 0.05 * (TickNoise.unit(boil, 40 + k) - 0.5), jy = 0.04 * (TickNoise.unit(boil, 50 + k) - 0.5)
            let ux = p.x + jx, uy = spot.up ? 1 - (p.y + jy) : p.y + jy
            let x = spot.box.minX + ux * spot.box.width, y = spot.box.minY + uy * spot.box.height
            return CGPoint(x: r.minX + (mirror ? 1 - x : x) * r.width, y: r.minY + y * r.height)
        }
        var path = Path()
        path.addLines(pts)
        path.closeSubpath()
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
        for i in b.shapes {
            let path = CapriFX.boltPath(i, mirror: b.mirror, boil: b.boil, in: r)
            // Фиолетовая «сбитая печать» под молнией, сама молния — малиновая с белыми блёстками.
            ctx.fill(path.offsetBy(dx: r.width * 0.012, dy: r.height * 0.03), with: .color(Palette.violet))
            ctx.fill(path, with: .color(Palette.crimson))
            var c = ctx
            c.clip(to: path)
            let box = path.boundingRect
            let dot = max(0.6, r.width * 0.004)
            var sparkles = Path()
            for k in 0..<40 {
                let x = box.minX + box.width * TickNoise.unit(i * 100 + k, 60 + b.boil % 3)
                let y = box.minY + box.height * TickNoise.unit(i * 100 + k, 70 + b.boil % 3)
                sparkles.addEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
            }
            c.fill(sparkles, with: .color(.white.opacity(0.85)))
        }
    }
}
