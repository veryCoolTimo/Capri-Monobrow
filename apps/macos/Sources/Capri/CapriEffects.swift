import SwiftUI
import CapriKit

/// Эффекты поверх глаз Capri, нарисованные кодом: глитч (сдвинутые полосы и разнос по цвету, как «relic» в
/// сериале) и её тонкие малиновые молнии-зигзаги со звёздочками (по рефу Тимофея) и фиолетовой «сбитой печатью».
/// Всё детерминировано по тику 12 fps.
enum CapriFX {
    /// Глитч по образцу сериала (маска с открытым ртом рассыпается): уровень 1 — сдвинутые полосы с цветным
    /// разносом; 2 — плюс кайма по краям фигур, рваный край кадра и цветные мазки (строка растянута в полосу);
    /// 3 — плюс сдвинутые блоки, цветные плашки и двойная экспозиция; 4 — «взлом» из конца той же сцены: кадр
    /// чёрно-белый, поверх — крупные ярко-розовые клинья, тонкие рваные строки и розовая молния-зигзаг.
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
        /// «Взлом»: розовые клинья (вершины в долях кадра) и молния-зигзаг.
        var shards: [[CGPoint]] = []
        var zigzag: [CGPoint] = []
    }

    /// Розовый «взлома» из сериала.
    static let hackPink = Color(red: 0.98, green: 0.33, blue: 0.59)

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
        case .alert: level = on(36, 6, 4, since) ? 4 : on(12, 1, 8) ? 1 : 0
        case .error: level = on(20, 3, 5) ? (TickNoise.unit(tick / 20, 14) < 0.5 ? 4 : 3) : on(7, 1, 10) ? 2 : 0
        case .vibing:
            // Смена трека — короткий глитч 1, без перехода уровня 2.
            return since < 3 ? make(level: 1, tick: tick, strength: 0.6) : nil
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
        guard level >= 4 else { return g }
        // Взлом: клинья-молнии с зубцом (в кадре 2:1 — по долям ширины и высоты), рваные строки чаще.
        g.ghost = 0
        g.blocks = []
        g.patches = []
        g.shards = (0..<(4 + Int(TickNoise.hash(tick / 2, 700) % 3))).map { (k: Int) -> [CGPoint] in
            let v = { (salt: Int) -> CGFloat in CGFloat(TickNoise.unit(tick / 2, 710 + k * 10 + salt)) }
            let cx: CGFloat = v(0), cy: CGFloat = v(1), len: CGFloat = 0.4 + 0.5 * v(2), w: CGFloat = 0.15 + 0.2 * v(3)
            let a: CGFloat = (v(4) - 0.5) * 0.9 + (v(5) < 0.5 ? CGFloat.pi : 0)
            let ux: CGFloat = cos(a), uy: CGFloat = sin(a) * 2, nx: CGFloat = -sin(a) / 2, ny: CGFloat = cos(a)
            let t: CGFloat = 0.35 + 0.3 * v(6), j: CGFloat = 0.4 + 0.5 * v(7)
            // Точка клина: `along` — вдоль (доли длины), `across` — поперёк (доли ширины).
            func at(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
                let dx: CGFloat = ux * len * along + nx * w * across
                let dy: CGFloat = uy * len * along + ny * w * across
                return CGPoint(x: cx + dx, y: cy + dy)
            }
            return [at(-0.5, 0.5), at(t - 0.5, j), at(t - 0.42, -0.1), at(0.5, 0), at(-0.5, -0.5)]
        }
        g.smears = (0..<(4 + Int(TickNoise.hash(tick, 800) % 4))).map { k in
            (y: u(801 + k * 4) * 0.95, h: 0.01 + 0.08 * u(802 + k * 4), src: u(803 + k * 4), tint: 0)
        }
        var x = 0.1 + 0.8 * u(900), y: CGFloat = -0.05
        g.zigzag = [CGPoint(x: x, y: y)]
        for k in 0..<8 where y < 1.05 {
            x += (0.06 + 0.1 * u(901 + k)) * (k % 2 == 0 ? 1 : -1)
            y += 0.12 + 0.18 * u(910 + k)
            g.zigzag.append(CGPoint(x: x, y: y))
        }
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
        case .vibing: nil
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
        needles(boltPoints(seed, boil: boil, in: r), width: r.height * 0.045, taper: 0.5, tip: 0.12)
    }

    /// Иглы по вершинам: колено `k` — от основания ширины `width·(1 − taper·k/n)` к острию за следующей вершиной
    /// (`tip` — доля колена).
    static func needles(_ pts: [CGPoint], width: CGFloat, taper: CGFloat, tip: CGFloat) -> Path {
        var path = Path()
        guard pts.count > 1 else { return path }
        for k in 0..<(pts.count - 1) {
            let p = pts[k], q = pts[k + 1]
            let dx = q.x - p.x, dy = q.y - p.y, len = max(1, (dx * dx + dy * dy).squareRoot())
            let w = width * (1 - taper * CGFloat(k) / CGFloat(pts.count))
            let end = CGPoint(x: q.x + dx * tip, y: q.y + dy * tip)
            path.addLines([CGPoint(x: p.x - dy / len * w / 2, y: p.y + dx / len * w / 2), end,
                           CGPoint(x: p.x + dy / len * w / 2, y: p.y - dx / len * w / 2)])
            path.closeSubpath()
        }
        return path
    }

    /// Вершины молнии между двумя произвольными точками (сцены на столе): зигзаг из `n` колен, амплитуда — доля
    /// длины, но не больше `maxAmp` pt; `reach` — какая доля пути уже пройдена.
    static func boltPoints(from a: CGPoint, to b: CGPoint, seed: Int, boil: Int, reach: CGFloat = 1, maxAmp: CGFloat = 26) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y, len = max(1, (dx * dx + dy * dy).squareRoot())
        let nx = -dy / len, ny = dx / len
        let n = max(4, min(14, Int(len / 60) + 4))
        let amp = min(maxAmp, len * 0.08)
        let reach = max(0, min(1, reach))
        var pts: [CGPoint] = []
        for k in 0..<n {
            let f = CGFloat(k) / CGFloat(n - 1)
            guard f <= reach + 0.0001 || k == 0 else {
                // Кончик — ровно на доле `reach`.
                let prev = pts[pts.count - 1]
                let tip = CGPoint(x: a.x + dx * reach, y: a.y + dy * reach)
                if hypot(tip.x - prev.x, tip.y - prev.y) > 1 { pts.append(tip) }
                break
            }
            let side: CGFloat = k == 0 || k == n - 1 ? 0 : (k % 2 == 0 ? 1 : -1) * (0.5 + 0.5 * CGFloat(TickNoise.unit(seed, 140 + k)))
            let jitter = (CGFloat(TickNoise.unit(boil, 160 + k)) - 0.5) * amp * 0.3
            pts.append(CGPoint(x: a.x + dx * f + nx * (amp * side + jitter), y: a.y + dy * f + ny * (amp * side + jitter)))
        }
        return pts
    }

    /// Контур тонкой молнии между точками: иглы от основания `width` к острию.
    static func boltPath(from a: CGPoint, to b: CGPoint, seed: Int, boil: Int, reach: CGFloat = 1, width: CGFloat = 3) -> Path {
        needles(boltPoints(from: a, to: b, seed: seed, boil: boil, reach: reach), width: width, taper: 0.4, tip: 0.1)
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

/// Раскодированные рисунки: PNG разжимается один раз (а не на каждый кадр и каждую копию глитча), последние 64
/// держатся в памяти (≈ 50 МБ на 576×360). Рисунки живут всё время работы (`ShowArt.shared`, `CapriArt`), так что
/// ключ — сам объект.
final class DecodedArt: @unchecked Sendable {
    static let shared = DecodedArt()
    static let capacity = 64

    private let lock = NSLock()
    private var cache: [ObjectIdentifier: CGImage] = [:]
    private var order: [ObjectIdentifier] = []

    func cgImage(_ image: NSImage) -> CGImage? {
        let key = ObjectIdentifier(image)
        lock.lock()
        if let hit = cache[key] {
            if let i = order.firstIndex(of: key) { order.remove(at: i) }
            order.append(key)
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let decoded = Self.decode(image) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        cache[key] = decoded
        order.append(key)
        while order.count > Self.capacity { cache[order.removeFirst()] = nil }
        return decoded
    }

    /// Рисует рисунок в растр его размера в пикселях — дальше кадр берёт готовые пиксели.
    private static func decode(_ image: NSImage) -> CGImage? {
        guard let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = src.width, h = src.height
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return src }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? src
    }
}

/// Кадр глаз с эффектами: рисунок вписан 2:1 (или, `fill`, заполняет кадр с обрезкой — крупная Capri в окнах,
/// с движением `face`), поверх — глитч и молнии (обрезаны по кадру).
struct CapriShotView: View {
    var image: NSImage?
    var glitch: CapriFX.Glitch?
    var bolt: CapriFX.Bolt?
    var fill = false
    var face: SceneFace?

    var body: some View {
        Canvas { ctx, size in
            guard let image, image.size.height > 0, size.height > 0 else { return }
            let aspect = image.size.width / image.size.height
            let r: CGRect
            // Где кадр виден: в fill рисунок больше кадра — глитч рисуем по видимой части, а не по всему рисунку.
            var view = CGRect(origin: .zero, size: size)
            if fill {
                let s = face ?? SceneFace()
                let th = CGFloat(s.tilt * .pi / 180)
                // Запас, чтобы сдвиг и наклон не открывали края.
                let over = 1 + 2 * abs(s.shift.dx) + 2 * abs(s.shift.dy) + abs(sin(th)) * (size.width / size.height + size.height / size.width)
                let w = max(size.width, size.height * aspect) * max(1, s.zoom) * over, h = w / aspect
                r = CGRect(x: (size.width - w) / 2 + s.shift.dx * size.width, y: (size.height - h) / 2 - s.shift.dy * size.height,
                           width: w, height: h)
                ctx.clip(to: Path(CGRect(origin: .zero, size: size)))
                if th != 0 {
                    ctx.translateBy(x: size.width / 2, y: size.height / 2)
                    ctx.rotate(by: .radians(-Double(th)))
                    ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
                }
            } else {
                let w = min(size.width, size.height * aspect), h = w / aspect
                r = CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
                ctx.clip(to: Path(r))
                view = r
            }
            if face?.mirror == true {
                ctx.translateBy(x: size.width, y: 0)
                ctx.scaleBy(x: -1, y: 1)
            }
            // Готовые пиксели (`DecodedArt`); крупное лицо — интерполяция попроще: она всё равно увеличена.
            let quality: Image.Interpolation = fill ? .medium : .high
            let base = DecodedArt.shared.cgImage(image).map { Image(decorative: $0, scale: 1) } ?? Image(nsImage: image)
            let art = ctx.resolve(base.resizable().interpolation(quality))
            ctx.draw(art, in: r)
            if let pulse = face?.pulse, pulse > 0 {
                // Вспышка на сильную долю: светлее (+12 %) и розовый отблеск.
                var c = ctx
                c.blendMode = .screen
                c.opacity = Double(pulse) * 0.12
                c.draw(art, in: r)
                c.opacity = Double(pulse) * 0.1
                c.fill(Path(r), with: .color(CapriFX.hackPink))
            }
            if let glitch { draw(glitch, art: art, in: r, view: view, ctx: ctx) }
            if let bolt { draw(bolt, in: r, ctx: ctx) }
        }
    }

    /// Глитч: двойная экспозиция → кайма → мазки → сдвинутые полосы с цветным разносом → блоки → плашки → рваный край.
    /// `r` — где рисунок, `v` — видимая часть кадра (полосы, блоки и край — по ней).
    private func draw(_ g: CapriFX.Glitch, art: GraphicsContext.ResolvedImage, in r: CGRect, view v: CGRect, ctx: GraphicsContext) {
        if g.level >= 4 { return hack(g, art: art, in: r, view: v, ctx: ctx) }
        func band(_ y: CGFloat, _ h: CGFloat) -> Path {
            Path(CGRect(x: v.minX, y: v.minY + y * v.height, width: v.width, height: h * v.height))
        }
        if g.ghost != 0 {
            var c = ctx
            c.opacity = 0.32
            c.draw(art, in: r.offsetBy(dx: g.ghost * v.width, dy: 0))
        }
        if g.level >= 2 {
            // Кайма: тонированные копии вразнос, «светлее» не выбеливает зелёный, но даёт цветной край у тёмного.
            for (color, dx) in [(Palette.violet, -g.split), (Palette.crimson, g.split)] {
                var c = ctx
                c.blendMode = .lighten
                c.addFilter(.colorMultiply(color))
                c.draw(art, in: r.offsetBy(dx: dx * v.width * 0.6, dy: 0))
            }
        }
        for m in g.smears {
            // Строка `src` растянута на всю полосу — горизонтальный мазок, сверху — цвет.
            var c = ctx
            c.clip(to: band(m.y, m.h))
            let k = max(1, m.h / 0.006)
            // Строка рисунка `src` растянута от верха полосы.
            c.draw(art, in: CGRect(x: r.minX, y: v.minY + m.y * v.height - m.src * r.height * k,
                                   width: r.width, height: r.height * k))
            c.blendMode = .screen
            c.fill(band(m.y, m.h), with: .color(CapriFX.tints[m.tint].opacity(0.45)))
        }
        for s in g.slices {
            var c = ctx
            c.clip(to: band(s.y, s.h))
            let shifted = r.offsetBy(dx: s.dx * v.width, dy: 0)
            c.draw(art, in: shifted)
            for (color, dx) in [(Palette.crimson, g.split), (Palette.violet, -g.split)] {
                var t = c
                t.blendMode = .screen
                t.opacity = 0.8
                t.addFilter(.colorMultiply(color))
                t.draw(art, in: shifted.offsetBy(dx: dx * v.width, dy: 0))
            }
        }
        for b in g.blocks {
            var c = ctx
            let rect = CGRect(x: v.minX + b.rect.minX * v.width, y: v.minY + b.rect.minY * v.height,
                              width: b.rect.width * v.width, height: b.rect.height * v.height)
            c.clip(to: Path(rect))
            c.draw(art, in: r.offsetBy(dx: b.dx * v.width, dy: b.dy * v.height))
        }
        for p in g.patches {
            var c = ctx
            c.blendMode = .screen
            c.fill(Path(CGRect(x: v.minX + p.rect.minX * v.width, y: v.minY + p.rect.minY * v.height,
                               width: p.rect.width * v.width, height: p.rect.height * v.height)),
                   with: .color(CapriFX.tints[p.tint].opacity(0.6)))
        }
        if g.tear != 0 {
            // Рваный край: короткие белые и чёрные штрихи по левому и правому краю.
            var white = Path(), black = Path()
            for k in 0..<18 {
                let y = v.minY + v.height * TickNoise.unit(g.tear, 600 + k)
                let w = v.width * (0.01 + 0.06 * TickNoise.unit(g.tear, 620 + k))
                let h = max(1, v.height * 0.008 * (1 + TickNoise.unit(g.tear, 640 + k)))
                let x = k % 2 == 0 ? v.minX : v.maxX - w
                if TickNoise.unit(g.tear, 660 + k) < 0.5 { white.addRect(CGRect(x: x, y: y, width: w, height: h)) }
                else { black.addRect(CGRect(x: x, y: y, width: w, height: h)) }
            }
            ctx.fill(white, with: .color(.white.opacity(0.8)))
            ctx.fill(black, with: .color(.black))
        }
    }

    /// Чёрно-белый с высоким контрастом: светлое — почти белое, тёмное — чёрное.
    private static let mono: ColorMatrix = {
        var m = ColorMatrix()
        let (wr, wg, wb, k, o): (Float, Float, Float, Float, Float) = (0.3, 0.59, 0.11, 4, -0.3)
        m.r1 = wr * k; m.r2 = wg * k; m.r3 = wb * k; m.r5 = o
        m.g1 = wr * k; m.g2 = wg * k; m.g3 = wb * k; m.g5 = o
        m.b1 = wr * k; m.b2 = wg * k; m.b3 = wb * k; m.b5 = o
        return m
    }()

    /// «Взлом»: чёрно-белый кадр, розовые клинья умножением (на белом — розовые, на чёрном — чёрные), рваные
    /// строки из растянутых строк и тонких штрихов, розовая молния-зигзаг, рваный край.
    private func hack(_ g: CapriFX.Glitch, art: GraphicsContext.ResolvedImage, in r: CGRect, view v: CGRect, ctx: GraphicsContext) {
        func at(_ p: CGPoint) -> CGPoint { CGPoint(x: v.minX + p.x * v.width, y: v.minY + p.y * v.height) }
        var mono = ctx
        mono.addFilter(.colorMatrix(Self.mono))
        mono.draw(art, in: r)
        var pink = ctx
        pink.blendMode = .multiply
        var shards = Path()
        for s in g.shards { shards.addLines(s.map(at)); shards.closeSubpath() }
        pink.fill(shards, with: .color(CapriFX.hackPink))
        var streaks: [Path] = [Path(), Path(), Path(), Path()]
        let colors: [Color] = [.white, Color(white: 0.82), Color(white: 0.25), CapriFX.hackPink]
        for (n, m) in g.smears.enumerated() {
            let y0 = v.minY + m.y * v.height, h = m.h * v.height
            var c = mono
            c.clip(to: Path(CGRect(x: v.minX, y: y0, width: v.width, height: h)))
            let k = max(1, m.h / 0.006)
            c.draw(art, in: CGRect(x: r.minX, y: y0 - m.src * r.height * k, width: r.width, height: r.height * k))
            c.fill(Path(CGRect(x: v.minX, y: y0, width: v.width, height: h)), with: .color(.white.opacity(0.3)))
            for i in 0..<24 {
                let x = v.minX + v.width * TickNoise.unit(n * 100 + i, 1000 + g.tear % 97)
                let yy = y0 + h * TickNoise.unit(n * 100 + i, 1100 + g.tear % 97)
                let w = v.width * (0.01 + 0.08 * TickNoise.unit(n * 100 + i, 1200 + g.tear % 97))
                streaks[i % 4].addRect(CGRect(x: x, y: yy, width: w, height: max(0.5, v.height * 0.005)))
            }
        }
        for (i, p) in streaks.enumerated() { ctx.fill(p, with: .color(colors[i])) }
        var zig = Path()
        zig.addLines(g.zigzag.map(at))
        ctx.stroke(zig, with: .color(CapriFX.hackPink), lineWidth: max(1.2, v.height * 0.016))
        var edge = Path()
        for k in 0..<16 {
            let y = v.minY + v.height * TickNoise.unit(g.tear, 600 + k)
            let w = v.width * (0.01 + 0.06 * TickNoise.unit(g.tear, 620 + k))
            edge.addRect(CGRect(x: k % 2 == 0 ? v.minX : v.maxX - w, y: y, width: w, height: max(1, v.height * 0.01)))
        }
        ctx.fill(edge, with: .color(.white))
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

/// Палитра из библии персонажа (по кадрам сериала; сами кадры в репозиторий не входят).
enum BiblePalette {
    /// Акцент переходов (скан-линия, кромка) — розовый, как прежняя молния.
    static let bolt = Color(red: 0xFB / 255, green: 0x46 / 255, blue: 0x88 / 255)
    /// Маска.
    static let mask = Color(red: 0, green: 0xFC / 255, blue: 0x67 / 255)
    /// Волосы/тело.
    static let hair = Color(red: 0xFB / 255, green: 0x0D / 255, blue: 0x49 / 255)
    /// Блёстки волос.
    static let sparkle = Color(red: 0xFB / 255, green: 0x46 / 255, blue: 0x88 / 255)
    /// Фиолетовая RGB-кромка.
    static let rim = Color(red: 0x7A / 255, green: 0x2C / 255, blue: 0xF4 / 255)

    static func flash(_ t: FlashTint) -> Color { t == .mask ? mask : hair }
}

/// Отрисовка общих переходов (`TransitionFrame` из CapriKit): содержимое полосами/столбцами, вспышка сплошным
/// цветом, лента волос, розовая игольчатая молния. Координаты уже локальные (панель, сверху вниз), кроме точек
/// молнии и ленты — их переводит `map`.
enum TransitionArt {
    /// Содержимое (глаза/лицо — символ Canvas размера `r`) по кадру перехода: полосы со сдвигом и RGB-разносом,
    /// столбцы со сдвигом и растяжением, сплющивание к средней линии.
    static func drawContent(_ fx: TransitionFrame, symbol: GraphicsContext.ResolvedSymbol, in r: CGRect, squash: CGFloat,
                            _ ctx: GraphicsContext) {
        var base = ctx
        let sq = max(0.02, squash * fx.squash)
        if sq < 1 {
            base.translateBy(x: 0, y: r.midY)
            base.scaleBy(x: 1 + (1 - sq) * 0.25, y: sq)
            base.translateBy(x: 0, y: -r.midY)
        }
        if !fx.bars.isEmpty {
            for bar in fx.bars where bar.shown {
                let band = CGRect(x: r.minX - abs(bar.dx) - 12, y: r.minY + r.height * bar.y, width: r.width + abs(bar.dx) * 2 + 24,
                                  height: r.height * bar.h + 0.5)
                var c = base
                c.clip(to: Path(band))
                if bar.split > 0.5 {
                    var red = c
                    red.addFilter(.colorMultiply(BiblePalette.hair))
                    red.blendMode = .screen
                    red.draw(symbol, in: r.offsetBy(dx: bar.dx - bar.split, dy: 0))
                    var cyan = c
                    cyan.addFilter(.colorMultiply(BiblePalette.bolt))
                    cyan.blendMode = .screen
                    cyan.draw(symbol, in: r.offsetBy(dx: bar.dx + bar.split, dy: 0))
                }
                c.draw(symbol, in: r.offsetBy(dx: bar.dx, dy: 0))
            }
            return
        }
        if !fx.columns.isEmpty {
            for col in fx.columns where col.shown {
                let x = r.minX + r.width * col.x
                var c = base
                c.clip(to: Path(CGRect(x: x, y: r.minY - r.height * 3, width: r.width * col.w + 0.5, height: r.height * 8)))
                c.opacity = Double(max(0, 1 - (col.stretch - 1) / 1.5 * 0.8))
                c.translateBy(x: 0, y: r.minY + col.drop)
                c.scaleBy(x: 1, y: col.stretch)
                c.draw(symbol, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
            }
            return
        }
        base.draw(symbol, in: r)
    }

    /// Вспышка сплошным цветом (как кадр сериала, залитый целиком): плашка из строк с рваными краями, сквозь
    /// неё — пара бирюзовых строк развёртки.
    static func drawFlash(_ f: TransitionFlash, in r: CGRect, _ ctx: GraphicsContext) {
        var c = ctx
        c.opacity = Double(f.alpha)
        var block = Path(), scan = Path()
        var y = r.minY, k = 0
        while y < r.maxY {
            let h = 3 + 5 * CGFloat(TickNoise.unit(f.seed &+ k, 1410))
            let l = (CGFloat(TickNoise.unit(f.seed &+ k, 1411)) - 0.3) * r.width * 0.18
            let w = r.width * (0.82 + 0.3 * CGFloat(TickNoise.unit(f.seed &+ k, 1412)))
            let row = CGRect(x: r.minX + l, y: y, width: w, height: min(h, r.maxY - y))
            if TickNoise.unit(f.seed &+ k, 1413) < 0.12 { scan.addRect(row.insetBy(dx: 0, dy: row.height * 0.35)) } else { block.addRect(row) }
            y += h
            k += 1
        }
        c.fill(block, with: .color(BiblePalette.flash(f.tint)))
        c.fill(scan, with: .color(BiblePalette.bolt))
    }

    /// Рваный многоугольник «взрыва» в прямоугольнике.
    static func burst(seed: Int, in r: CGRect) -> Path {
        var path = Path()
        let n = 18
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            let k: CGFloat = i % 2 == 0 ? 0.75 + 0.25 * CGFloat(TickNoise.unit(seed &+ i, 1400)) : 0.38 + 0.2 * CGFloat(TickNoise.unit(seed &+ i, 1401))
            let p = CGPoint(x: r.midX + cos(a) * r.width / 2 * k, y: r.midY + sin(a) * r.height / 2 * k)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// Лента волос: видимая часть ломаной между `tail` и `head`; малиновая с фиолетовой кромкой и блёстками.
    static func drawRibbon(_ rb: TransitionRibbon, map: (CGPoint) -> CGPoint, _ ctx: GraphicsContext) {
        let pts = rb.points.map(map)
        guard pts.count > 1 else { return }
        let lens = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lens.reduce(0, +)
        func point(_ f: CGFloat) -> (CGPoint, Int) {
            var left = total * f
            for (i, l) in lens.enumerated() {
                if left <= l, l > 0 {
                    let k = left / l
                    return (CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * k, y: pts[i].y + (pts[i + 1].y - pts[i].y) * k), i)
                }
                left -= l
            }
            return (pts[pts.count - 1], pts.count - 2)
        }
        let (a, ia) = point(rb.tail), (b, ib) = point(rb.head)
        var line = Path()
        line.move(to: a)
        if ib > ia { for i in (ia + 1)...ib { line.addLine(to: pts[i]) } }
        line.addLine(to: b)
        let style = { (w: CGFloat) in StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .miter) }
        // Фиолетовая RGB-кромка, малиновое тело, светлая блёстка по краю.
        ctx.stroke(line.offsetBy(dx: 2.5, dy: 2), with: .color(BiblePalette.rim), style: style(rb.width))
        ctx.stroke(line.offsetBy(dx: -1.5, dy: -1), with: .color(BiblePalette.bolt.opacity(0.7)), style: style(rb.width * 0.9))
        ctx.stroke(line, with: .color(BiblePalette.hair), style: style(rb.width))
        ctx.stroke(line.offsetBy(dx: -rb.width * 0.22, dy: -rb.width * 0.22), with: .color(BiblePalette.sparkle),
                   style: style(max(1, rb.width * 0.18)))
        // Голова ленты — острый клин.
        let d = CGVector(dx: b.x - a.x, dy: b.y - a.y), len = max(1, hypot(d.dx, d.dy))
        let ux = d.dx / len, uy = d.dy / len
        var tip = Path()
        tip.addLines([CGPoint(x: b.x - uy * rb.width * 0.6, y: b.y + ux * rb.width * 0.6),
                      CGPoint(x: b.x + ux * rb.width * 1.4, y: b.y + uy * rb.width * 1.4),
                      CGPoint(x: b.x + uy * rb.width * 0.6, y: b.y - ux * rb.width * 0.6)])
        tip.closeSubpath()
        ctx.fill(tip, with: .color(BiblePalette.hair))
    }

    /// Молния — прежняя розовая игольчатая (`CapriFX.boltPath`) с фиолетовой тенью: Тимофею она нравится
    /// больше бирюзовой из отрезков. Путь `TransitionBolt` задаёт только концы и «кипение».
    static func drawBolt(_ b: TransitionBolt, map: (CGPoint) -> CGPoint, width: CGFloat, _ ctx: GraphicsContext) {
        guard let first = b.main.first, let last = b.main.last else { return }
        let a = map(first), z = map(last)
        let seed = Int(first.x * 7 + first.y * 13 + last.x * 3) & 0xFFFF
        let boil = b.main.count &+ Int(b.main.reduce(0) { $0 + $1.x + $1.y }) & 0xFF
        let path = CapriFX.boltPath(from: a, to: z, seed: seed / 2 + 7, boil: boil, width: width)
        ctx.fill(path.offsetBy(dx: 1.2, dy: 1.5), with: .color(Palette.violet))
        ctx.fill(path, with: .color(Palette.crimson))
    }
}
