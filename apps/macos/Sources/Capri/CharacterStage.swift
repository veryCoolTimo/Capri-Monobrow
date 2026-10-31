import AppKit
import SwiftUI
import Combine
import CapriKit

// Сцены персонажа на рабочем столе. Панель — рецепт NotchPanel: без рамки, не активирует приложение, не становится
// ключевой, прозрачная, клики проходят насквозь (кроме «×» в сцене «окно»). Есть только во время сцены (≤ 8 с);
// вне сцены — `orderOut`, TimelineView снят, CPU ≈ 0. Полноэкранные пространства — нет (`.fullScreenAuxiliary` не
// ставим). Компьютером Capri не управляет: курсор, текст и окно — рисунок в этой панели.

final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Тексты сцены — из живых данных.
struct SceneContent: Equatable {
    /// Строка статуса окна: «2 ждут · votek2», «всё тихо», «♪ Artist — Track».
    var status = "всё тихо"
    /// Строки «захвата».
    var lines = ["> capri attach", "ACCESS ▮▮▮"]
}

/// Идущая сцена.
struct SceneRun: Equatable {
    var kind: SceneKind
    var start: Date
    var geometry: SceneGeometry
    /// Начало панели (глобально) и её размер.
    var origin: CGPoint
    var size: CGSize
    var clips: Set<String>
    var content: SceneContent
    var abortedAt: Double?
    /// Для снимков: прямоугольник «окна под панелью» (подложка).
    var backdropWindow: CGRect?

    var end: Double { abortedAt.map { $0 + SceneTimeline.recallDuration } ?? SceneTimeline.duration(kind) }

    func frame(at t: Double) -> SceneFrame {
        SceneTimeline.frame(kind, t: t, geometry: geometry, clips: clips, text: content.status.count,
                            lines: content.lines.map(\.count), abortedAt: abortedAt)
    }
}

final class StageModel: ObservableObject {
    @Published var run: SceneRun?
}

/// Расписание кадров сцены: 24 fps, в спокойной части (`SceneTimeline.calm`) — 12 fps. Панель сцены большая
/// (notch ∪ цель), каждый кадр перерисовывает её целиком — лишние кадры в покое стоят батареи.
struct SceneSchedule: TimelineSchedule {
    var run: SceneRun

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var t = max(0, startDate.timeIntervalSince(run.start))
        let end = run.end + 0.1
        return AnyIterator {
            guard t <= end else { return nil }
            let date = run.start.addingTimeInterval(t)
            t += SceneTimeline.frameInterval(run.kind, t: t, aborted: run.abortedAt != nil)
            return date
        }
    }
}

/// Живой показ, только пока есть сцена.
struct SceneView: View {
    @ObservedObject var model: StageModel

    var body: some View {
        if let run = model.run {
            TimelineView(SceneSchedule(run: run)) { ctx in
                let t = ctx.date.timeIntervalSince(run.start)
                SceneCanvas(run: run, t: t, frame: run.frame(at: t))
            }
        } else {
            Color.clear
        }
    }
}

/// Кадр сцены: подложка (рамка окна, захват) → глаза → передний план (молния, вспышка, курсор, ноты).
struct SceneCanvas: View {
    var run: SceneRun
    var t: Double
    var frame: SceneFrame
    /// Снимок: тёмный «рабочий стол» и муляж окна под сценой.
    var backdrop = false

    /// Глобальные координаты AppKit → координаты панели (SwiftUI, от верхнего левого угла).
    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - run.origin.x, y: run.size.height - (p.y - run.origin.y)) }
    func local(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - run.origin.x, y: run.size.height - (r.maxY - run.origin.y), width: r.width, height: r.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if backdrop { Canvas { ctx, size in drawBackdrop(ctx, size) } }
            Canvas { ctx, _ in drawBack(ctx) }
            if let e = frame.eyes {
                let r = local(e)
                SceneEyes(frame: frame, t: t)
                    .frame(width: r.width, height: r.height)
                    .scaleEffect(x: 1 + (1 - frame.squash) * 0.25, y: max(0.02, frame.squash))
                    .position(x: r.midX, y: r.midY)
            }
            Canvas { ctx, _ in drawFront(ctx) }
        }
        .frame(width: run.size.width, height: run.size.height)
        .allowsHitTesting(false)
    }

    // MARK: подложка снимка

    private func drawBackdrop(_ ctx: GraphicsContext, _ size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [Color(white: 0.2), Color(white: 0.12)]),
                                       startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        if let w = run.backdropWindow {
            let r = local(w)
            ctx.fill(Path(roundedRect: r, cornerRadius: 10), with: .color(Color(white: 0.07)))
            ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: 26)), with: .color(Color(white: 0.16)))
            for k in 0..<12 {
                let y = r.minY + 40 + CGFloat(k) * 16
                guard y < r.maxY - 10 else { break }
                let len = r.width * (0.2 + 0.6 * CGFloat(TickNoise.unit(k, 3)))
                ctx.fill(Path(CGRect(x: r.minX + 14, y: y, width: len, height: 6)), with: .color(Color(white: 0.3)))
            }
        }
        // Вырез и строка меню.
        let home = local(run.geometry.home)
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: max(0, home.maxY + 4))), with: .color(Color(white: 0.28)))
        ctx.fill(Path(roundedRect: CGRect(x: home.maxX + 14, y: -10, width: 180, height: home.maxY + 14), cornerRadius: 10),
                 with: .color(.black))
    }

    // MARK: подложка: окно и захват

    private func drawBack(_ ctx: GraphicsContext) {
        if let w = frame.window { drawWindow(w, ctx) }
        if let k = frame.takeover { drawTakeover(k, ctx) }
    }

    private func drawWindow(_ w: SceneWindow, _ ctx: GraphicsContext) {
        let r = local(w.rect)
        let pink = CapriFX.hackPink
        if w.open < 0.5 {
            // Линия глаз растёт в стороны.
            ctx.fill(Path(r), with: .color(pink))
            return
        }
        var c = ctx
        if w.melt > 0 { c.opacity = Double(max(0, 1 - w.melt * 1.4)) }
        c.fill(Path(r), with: .color(Color(red: 0.03, green: 0.02, blue: 0.04).opacity(0.93)))
        // Сканлайны.
        var scan = Path()
        var y = r.minY + 1
        while y < r.maxY { scan.addRect(CGRect(x: r.minX, y: y, width: r.width, height: 1)); y += 3 }
        c.fill(scan, with: .color(pink.opacity(0.06)))
        if w.open < 1 {
            // Вайп сверху вниз во время раскрытия.
            let k = (w.open - 0.5) * 2
            c.fill(Path(CGRect(x: r.minX, y: r.minY + r.height * k - 2, width: r.width, height: 2)), with: .color(pink.opacity(0.9)))
        }
        c.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink), lineWidth: 1)
        if w.chrome {
            let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: 22)
            c.fill(Path(CGRect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1)), with: .color(pink.opacity(0.7)))
            c.fill(Path(CGRect(x: bar.minX + 1, y: bar.minY + 1, width: 3, height: bar.height - 2)), with: .color(pink))
            c.draw(Text("CAPRI//SYS" + (w.caret ? " ▮" : "  ")).font(.mono(9, .bold)).foregroundColor(pink),
                   at: CGPoint(x: bar.minX + 10, y: bar.midY), anchor: .leading)
            let x = local(SceneTimeline.closeRect(w.rect))
            c.stroke(Path(x.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink.opacity(0.8)), lineWidth: 1)
            var cross = Path()
            cross.move(to: CGPoint(x: x.minX + 5, y: x.minY + 5)); cross.addLine(to: CGPoint(x: x.maxX - 5, y: x.maxY - 5))
            cross.move(to: CGPoint(x: x.maxX - 5, y: x.minY + 5)); cross.addLine(to: CGPoint(x: x.minX + 5, y: x.maxY - 5))
            c.stroke(cross, with: .color(pink), lineWidth: 1.4)
            // Строка статуса, печатается побуквенно.
            let text = String(run.content.status.prefix(w.typed))
            let caret = w.typed < run.content.status.count || w.caret ? "▮" : " "
            c.draw(Text("> " + text + caret).font(.mono(11, .semibold)).foregroundColor(Palette.text),
                   at: CGPoint(x: r.minX + 12, y: r.maxY - 18), anchor: .leading)
            // Уголки-скобки HUD.
            var ticks = Path()
            for (px, py, sx, sy) in [(r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                ticks.move(to: CGPoint(x: px + 4 * sx, y: py + 10 * sy)); ticks.addLine(to: CGPoint(x: px + 4 * sx, y: py + 4 * sy))
                ticks.addLine(to: CGPoint(x: px + 10 * sx, y: py + 4 * sy))
            }
            c.stroke(ticks, with: .color(pink.opacity(0.7)), lineWidth: 1)
        }
    }

    private func drawTakeover(_ k: SceneTakeover, _ ctx: GraphicsContext) {
        let a = local(k.area)
        var c = ctx
        // Финал: всё сжимается в линию по центру области.
        if k.collapse < 1 {
            c.translateBy(x: 0, y: a.midY)
            c.scaleBy(x: 1, y: max(0.01, k.collapse))
            c.translateBy(x: 0, y: -a.midY)
        }
        c.clip(to: Path(a))
        let pink = CapriFX.hackPink
        let tick = Int(t * 24)
        let h = a.height * k.wave
        let wave = CGRect(x: a.minX, y: a.minY, width: a.width, height: h)
        if h > 0 {
            var w = c
            w.clip(to: Path(wave))
            if let mosh = SceneArt.texture(SceneClip.texMosh, t: t) {
                w.opacity = 0.42
                w.draw(Image(nsImage: mosh).resizable(), in: a)
                w.opacity = 1
                w.fill(Path(wave), with: .color(pink.opacity(0.12)))
            } else {
                // Процедурный датамош: редкие розовые и синие полосы и сдвинутые блоки, между ними видно окно.
                w.fill(Path(wave), with: .color(pink.opacity(0.1)))
                var y = a.minY
                var n = 0
                while y < a.minY + h {
                    let bh = 2 + 14 * CGFloat(TickNoise.unit(n, 70 + tick / 3))
                    let gap = 4 + 26 * CGFloat(TickNoise.unit(n, 74))
                    let blue = TickNoise.unit(n, 71) < 0.3
                    let alpha = 0.15 + 0.4 * TickNoise.unit(n, 72 + tick / 2)
                    let x0 = a.minX + a.width * CGFloat(TickNoise.unit(n, 75)) * 0.5
                    let wd = a.width * (0.25 + 0.75 * CGFloat(TickNoise.unit(n, 76)))
                    let dx = (CGFloat(TickNoise.unit(n, 73 + tick)) - 0.5) * 30
                    w.fill(Path(CGRect(x: x0 + dx, y: y, width: wd, height: bh)),
                           with: .color((blue ? Palette.violet : pink).opacity(alpha)))
                    y += bh + gap
                    n += 1
                }
            }
            // Сканлайны и кромка волны.
            var scan = Path()
            var sy = a.minY
            while sy < a.minY + h { scan.addRect(CGRect(x: a.minX, y: sy, width: a.width, height: 1)); sy += 3 }
            w.fill(scan, with: .color(.black.opacity(0.25)))
            if k.wave < 1 {
                c.fill(Path(CGRect(x: a.minX, y: a.minY + h - 2, width: a.width, height: 3)), with: .color(pink))
                c.fill(Path(CGRect(x: a.minX, y: a.minY + h + 3, width: a.width, height: 1)), with: .color(Palette.violet.opacity(0.8)))
            }
        }
        // Граффити: розовые пятна с потёками.
        if k.graffiti > 0 {
            var g = c
            g.opacity = Double(k.graffiti)
            if let tex = SceneArt.texture(SceneClip.texGraffiti, t: t) {
                g.blendMode = .screen
                g.draw(Image(nsImage: tex).resizable(), in: CGRect(x: a.minX + a.width * 0.3, y: a.minY + a.height * 0.25,
                                                                   width: a.width * 0.6, height: a.width * 0.3))
            } else {
                for i in 0..<4 {
                    let cx = a.minX + a.width * (0.12 + 0.62 * CGFloat(TickNoise.unit(i, 90)))
                    let cy = a.minY + a.height * (0.3 + 0.45 * CGFloat(TickNoise.unit(i, 91)))
                    let r0 = (14 + 24 * CGFloat(TickNoise.unit(i, 92))) * min(1, k.graffiti * 1.4)
                    var blob = Path()
                    // Клякса: 14 лучей разной длины, по краю — брызги, вниз — 1–3 тонких потёка разной длины.
                    for j in 0..<14 {
                        let ang = CGFloat(j) / 14 * 2 * .pi
                        let rr = r0 * (j % 2 == 0 ? 0.55 + 0.6 * CGFloat(TickNoise.unit(i * 20 + j, 93)) : 0.45)
                        let p = CGPoint(x: cx + cos(ang) * rr, y: cy + sin(ang) * rr * 0.75)
                        if j == 0 { blob.move(to: p) } else { blob.addLine(to: p) }
                    }
                    blob.closeSubpath()
                    for d in 0..<6 {
                        let ang = CGFloat(TickNoise.unit(i * 7 + d, 95)) * 2 * .pi
                        let dist = r0 * (1.1 + 0.7 * CGFloat(TickNoise.unit(i * 7 + d, 96)))
                        let s = 1.5 + 3 * CGFloat(TickNoise.unit(i * 7 + d, 97))
                        blob.addEllipse(in: CGRect(x: cx + cos(ang) * dist, y: cy + sin(ang) * dist * 0.75, width: s, height: s))
                    }
                    for d in 0..<(1 + Int(TickNoise.hash(i, 98) % 3)) {
                        let dx = cx + (CGFloat(TickNoise.unit(i * 3 + d, 94)) - 0.5) * r0
                        let len = r0 * (0.3 + 1.6 * CGFloat(TickNoise.unit(i * 3 + d, 99))) * k.graffiti
                        let wd = 1.2 + 1.5 * CGFloat(TickNoise.unit(i * 3 + d, 100))
                        blob.addRoundedRect(in: CGRect(x: dx, y: cy, width: wd, height: r0 * 0.4 + len), cornerSize: CGSize(width: wd / 2, height: wd / 2))
                    }
                    g.fill(blob, with: .color(pink.opacity(0.9)))
                }
            }
        }
        // Сами печатаются строки.
        for (i, line) in run.content.lines.enumerated() where i < k.typed.count && k.typed[i] > 0 {
            let s = String(line.prefix(k.typed[i]))
            let y = a.minY + 26 + CGFloat(i) * 22
            let caret = k.typed[i] < line.count ? "▮" : ""
            c.fill(Path(CGRect(x: a.minX + 14, y: y - 9, width: CGFloat(s.count + 1) * 8.2 + 8, height: 18)),
                   with: .color(.black.opacity(0.7)))
            c.draw(Text(s + caret).font(.mono(13, .bold)).foregroundColor(i == 0 ? Palette.text : pink),
                   at: CGPoint(x: a.minX + 18, y: y), anchor: .leading)
        }
        c.stroke(Path(a.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink.opacity(0.6 * Double(k.wave))), lineWidth: 1)
    }

    // MARK: передний план

    private func drawFront(_ ctx: GraphicsContext) {
        if let b = frame.bolt { drawBolt(b, ctx, width: 3) }
        if frame.flash > 0, let at = frame.flashAt {
            // Вспышка 2 кадра: белое ядро-звезда и розовое кольцо, без мягкого «шара».
            let p = local(at), f = Double(frame.flash)
            let r: CGFloat = 26 + 30 * (1 - frame.flash)
            var star = Path()
            for i in 0..<16 {
                let a = CGFloat(i) * .pi / 8, rad = i % 2 == 0 ? r : r * 0.22
                let q = CGPoint(x: p.x + cos(a) * rad, y: p.y + sin(a) * rad * 0.7)
                if i == 0 { star.move(to: q) } else { star.addLine(to: q) }
            }
            star.closeSubpath()
            var c = ctx
            c.opacity = f
            c.fill(star, with: .color(.white))
            c.stroke(Path(ellipseIn: CGRect(x: p.x - r * 1.2, y: p.y - r * 0.84, width: r * 2.4, height: r * 1.68)),
                     with: .color(CapriFX.hackPink), lineWidth: 2)
        }
        if let w = frame.window, w.melt > 0 { drawMelt(w, ctx) }
        if let k = frame.takeover { drawTakeoverFront(k, ctx) }
        for n in frame.notes {
            let glyph = ["♪", "♫", "♬"][n.glyph % 3]
            var c = ctx
            c.opacity = Double(n.alpha)
            c.draw(Text(glyph).font(.system(size: 22, weight: .heavy)).foregroundColor(Palette.violet), at: local(n.center).applying(.init(translationX: 1.5, y: 1.5)))
            c.draw(Text(glyph).font(.system(size: 22, weight: .heavy)).foregroundColor(CapriFX.hackPink), at: local(n.center))
        }
    }

    private func drawBolt(_ b: SceneBolt, _ ctx: GraphicsContext, width: CGFloat) {
        let a = local(b.from), z = local(b.to)
        let path = CapriFX.boltPath(from: a, to: z, seed: b.seed / 2 + 7, boil: b.seed, reach: b.reach, width: width)
        ctx.fill(path.offsetBy(dx: 1.2, dy: 1.5), with: .color(Palette.violet))
        ctx.fill(path, with: .color(Palette.crimson))
    }

    /// Окно рассыпается: квадратики рамки падают и гаснут.
    private func drawMelt(_ w: SceneWindow, _ ctx: GraphicsContext) {
        let r = local(w.rect)
        let cols = 28, rows = 17
        let cw = r.width / CGFloat(cols), ch = r.height / CGFloat(rows)
        var pink = Path(), dark = Path()
        for i in 0..<cols {
            for j in 0..<rows {
                let n = i * 31 + j
                let delay = CGFloat(TickNoise.unit(n, 120)) * 0.5 + CGFloat(rows - j) / CGFloat(rows) * 0.3
                let k = max(0, min(1, (w.melt - delay) / 0.4))
                guard k > 0, k < 1, TickNoise.unit(n, 121) < 0.55 else { continue }
                let size = max(1, cw * (1 - k * 0.7))
                let x = r.minX + CGFloat(i) * cw + (CGFloat(TickNoise.unit(n, 122)) - 0.5) * 30 * k
                let y = r.minY + CGFloat(j) * ch + k * k * 120
                let rect = CGRect(x: x, y: y, width: size, height: size)
                if j == 0 || i == 0 || i == cols - 1 || TickNoise.unit(n, 123) < 0.35 { pink.addRect(rect) } else { dark.addRect(rect) }
            }
        }
        ctx.fill(dark, with: .color(Color(white: 0.12).opacity(0.9)))
        ctx.fill(pink, with: .color(CapriFX.hackPink))
    }

    private func drawTakeoverFront(_ k: SceneTakeover, _ ctx: GraphicsContext) {
        let a = local(k.area)
        for ring in k.rings {
            let p = local(ring.center)
            let rr = 6 + 22 * ring.progress
            var c = ctx
            c.opacity = Double(1 - ring.progress)
            c.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)), with: .color(CapriFX.hackPink), lineWidth: 2)
            c.stroke(Path(ellipseIn: CGRect(x: p.x - rr * 0.5, y: p.y - rr * 0.5, width: rr, height: rr)), with: .color(Palette.acid), lineWidth: 1)
        }
        if let cur = k.cursor {
            let p = local(cur)
            // Нарисованный курсор с RGB-разносом — розовый, чтобы не спутать с настоящим.
            var arrow = Path()
            arrow.addLines([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 20), CGPoint(x: 5, y: 15), CGPoint(x: 9, y: 23),
                            CGPoint(x: 12, y: 22), CGPoint(x: 8, y: 14), CGPoint(x: 14, y: 14)])
            arrow.closeSubpath()
            let at = arrow.applying(CGAffineTransform(scaleX: 1.5, y: 1.5)).offsetBy(dx: p.x, dy: p.y)
            ctx.fill(at.offsetBy(dx: -2, dy: 0), with: .color(Color(red: 0.2, green: 0.9, blue: 1).opacity(0.75)))
            ctx.fill(at.offsetBy(dx: 2, dy: 1), with: .color(Palette.violet.opacity(0.8)))
            ctx.fill(at, with: .color(CapriFX.hackPink))
            ctx.stroke(at, with: .color(.white), lineWidth: 1)
        }
        if let seed = k.edgeBolt {
            // Тонкая красная молния вдоль верхнего или правого края.
            let top = seed % 2 == 0
            let from = top ? CGPoint(x: a.minX + a.width * 0.1, y: a.minY + 2) : CGPoint(x: a.maxX - 2, y: a.minY + a.height * 0.1)
            let to = top ? CGPoint(x: a.minX + a.width * 0.7, y: a.minY + 4) : CGPoint(x: a.maxX - 4, y: a.minY + a.height * 0.8)
            let path = CapriFX.boltPath(from: from, to: to, seed: seed, boil: Int(t * 12), width: 1.6)
            ctx.fill(path, with: .color(Palette.crimson))
        }
    }
}

/// Глаза сцены: клип сериала (или встроенный кадр) с глитчем.
struct SceneEyes: View {
    var frame: SceneFrame
    var t: Double

    var body: some View {
        let tick = Int(t * CapriFace.fps)
        CapriShotView(image: SceneArt.image(frame.clip, t: frame.clipT, loop: frame.loop),
                      glitch: frame.glitch > 0 ? CapriFX.make(level: frame.glitch, tick: tick, strength: 1) : nil,
                      bolt: nil)
    }
}

/// Рисунки для сцен: клипы сериала из `~/.capri/art/eyes`, иначе встроенные кадры.
enum SceneArt {
    /// Какие клипы есть (для фолбэков таймлайна).
    static var clips: Set<String> {
        if let show = ShowArt.shared { return Set(show.clips.keys) }
        return []
    }

    static func image(_ clip: String, t: Double, loop: Bool) -> NSImage? {
        if let show = ShowArt.shared { return show.image(clip: clip, t: t, loop: loop) }
        return CapriArt.images[CapriArt.frame(clip: clip, t: t)]
    }

    /// Текстура «захвата» (кадр клипа `tex_*`), если есть.
    static func texture(_ name: String, t: Double) -> NSImage? {
        guard let show = ShowArt.shared, let c = show.clip(named: name), !c.frames.isEmpty else { return nil }
        return c.frame(at: Int(t * 8), loop: true).map { show.images[$0] }
    }
}

/// Прозрачная кнопка «×» (единственная кликабельная точка сцены).
final class StageCloseView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Показ сцен: панель, таймер конца, «×», обрыв. Решения «можно ли» — у `CharacterDirector`.
final class StageController {
    let model = StageModel()
    private var panel: StagePanel?
    private var closeView: StageCloseView?
    private var endWork: DispatchWorkItem?
    private var mouseTimer: Timer?
    /// Глаза в notch (глобально).
    var home: () -> CGRect? = { nil }
    var screen: () -> NSScreen? = { nil }
    var content: () -> SceneContent = { SceneContent() }
    /// Сцена началась/кончилась — notch прячет/показывает свои глаза.
    var onRunning: ((Bool) -> Void)?
    var log: ((String) -> Void)?
    private(set) var suppressed = false
    private(set) var lastTarget = ""

    var running: Bool { model.run != nil }

    /// Время от начала сцены.
    var elapsed: Double? { model.run.map { Date().timeIntervalSince($0.start) } }

    // MARK: геометрия

    /// Сцена на экране notch; `variant` — `corner|window` (телепорт), `terminal|corner` (захват).
    func makeRun(_ kind: SceneKind, variant: String? = nil, backdrop: Bool = false) -> SceneRun? {
        guard let screen = screen() else { return nil }
        let visible = screen.visibleFrame
        let home = self.home() ?? CGRect(x: screen.frame.midX - 120, y: screen.frame.maxY - 22, width: 32, height: 16)
        let corner = SceneLayout.corner(visible, size: SceneTimeline.eyesSize)
        let front = Self.frontWindow(on: screen)
        var target = corner, area: CGRect?, backdropWindow: CGRect?
        lastTarget = "corner"
        switch kind {
        case .teleport:
            if variant != "corner", let w = front?.rect, let on = SceneLayout.onWindow(w, visible: visible) {
                target = on; lastTarget = "window"; backdropWindow = w
            } else if variant == "window", backdrop {
                // Снимок без подходящего окна: муляж окна посреди экрана.
                let w = CGRect(x: visible.midX - 300, y: visible.midY - 220, width: 640, height: 400)
                target = SceneLayout.onWindow(w, visible: visible) ?? corner; backdropWindow = w; lastTarget = "window(mock)"
            }
        case .window:
            area = SceneLayout.windowForm(visible)
            target = SceneTimeline.eyesInWindow(area!)
        case .takeover:
            var w: CGRect?
            if variant != "corner", let f = front, f.terminal || variant == "terminal" { w = f.rect }
            if w == nil, variant == "terminal", backdrop {
                w = CGRect(x: visible.maxX - 760, y: visible.minY + 60, width: 700, height: 440)
            }
            area = SceneLayout.takeoverArea(window: w, visible: visible)
            lastTarget = w == nil ? "corner" : "terminal"
            backdropWindow = w
            target = SceneTimeline.eyesInArea(area!)
        case .vibe:
            break
        }
        let g = SceneGeometry(home: home, target: target, area: area, visible: visible, cursor: NSEvent.mouseLocation)
        let bounds = g.bounds.intersection(screen.frame).integral
        guard !bounds.isNull, bounds.width > 0 else { return nil }
        return SceneRun(kind: kind, start: Date(), geometry: g, origin: bounds.origin, size: bounds.size,
                        clips: SceneArt.clips, content: content(), abortedAt: nil, backdropWindow: backdrop ? backdropWindow : nil)
    }

    struct FrontWindow { var rect: CGRect; var terminal: Bool; var pid: Int32 }

    /// Переднее окно переднего приложения на экране notch — рамка без названия (без разрешения на запись экрана).
    static func frontWindow(on screen: NSScreen) -> FrontWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // Список — спереди назад: первое обычное окно приложения и есть его переднее. Оно на другом экране — сидеть
        // не на чем (не берём окно того же приложения, спрятанное под другими).
        guard let w = raw.compactMap(WindowInfo.from).first(where: { w in
            w.pid == app.processIdentifier && w.layer == 0 && w.alpha > 0 && w.bounds.width >= 200 && w.bounds.height >= 120
        }) else { return nil }
        let r = SceneLayout.appKit(w.bounds, primaryHeight: primary)
        guard screen.frame.contains(CGPoint(x: r.midX, y: r.midY)) else { return nil }
        return FrontWindow(rect: r, terminal: SceneLayout.terminals.contains(app.bundleIdentifier ?? ""), pid: app.processIdentifier)
    }

    // MARK: показ

    @discardableResult
    func play(_ kind: SceneKind, variant: String? = nil) -> Bool {
        guard !suppressed else { log?("scene \(kind.rawValue): skip fullscreen"); return false }
        stop()
        guard let run = makeRun(kind, variant: variant) else { log?("scene \(kind.rawValue): no screen"); return false }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(CGRect(origin: run.origin, size: run.size), display: false)
        panel.ignoresMouseEvents = true
        model.run = run
        panel.orderFrontRegardless()
        onRunning?(true)
        log?("scene \(kind.rawValue) → \(lastTarget) frame=\(NSStringFromRect(panel.frame))")
        scheduleEnd(after: run.end)
        if kind == .window { startCloseTracking() }
        return true
    }

    private func makePanel() -> StagePanel {
        let p = StagePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Над notch (mainMenu + 3): глаза уходят из notch и возвращаются в него. Клики всё равно проходят насквозь.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        let container = NSView()
        let host = NSHostingView(rootView: SceneView(model: model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let close = StageCloseView()
        close.isHidden = true
        close.onClick = { [weak self] in self?.log?("scene: × clicked"); self?.stop() }
        container.addSubview(close)
        closeView = close
        p.contentView = container
        return p
    }

    private func scheduleEnd(after seconds: Double) {
        endWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, seconds) + 0.05, execute: work)
    }

    /// «×» кликабелен только пока над ним мышь (опрос 30 раз в секунду только во время сцены «окно» — окно, когда
    /// клик мимо «×» ловит панель, ≤ 33 мс).
    private func startCloseTracking() {
        mouseTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.trackClose() }
        RunLoop.main.add(t, forMode: .common)
        mouseTimer = t
    }

    private func trackClose() {
        guard let run = model.run, let panel, let w = run.geometry.area, let t = elapsed else { return }
        let f = run.frame(at: t)
        let x = SceneTimeline.closeRect(w)
        let active = f.window?.chrome == true && run.abortedAt == nil
        let over = active && x.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
        if let cv = closeView {
            let local = CGRect(x: x.minX - run.origin.x - 3, y: x.minY - run.origin.y - 3, width: x.width + 6, height: x.height + 6)
            if cv.frame != local { cv.frame = local }
            cv.isHidden = !active
        }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    /// Обрыв (кто-то ждёт ответа, notch раскрыли): молния домой за 0.35 с.
    func abort(_ why: String) {
        guard var run = model.run, run.abortedAt == nil, let t = elapsed else { return }
        guard t < SceneTimeline.duration(run.kind) - SceneTimeline.recallDuration else { return }
        run.abortedAt = t
        model.run = run
        panel?.ignoresMouseEvents = true
        closeView?.isHidden = true
        log?("scene abort (\(why)) at \(String(format: "%.2f", t))")
        scheduleEnd(after: run.end - t)
    }

    /// Сразу убрать панель.
    func stop() {
        endWork?.cancel(); endWork = nil
        mouseTimer?.invalidate(); mouseTimer = nil
        let was = model.run != nil
        model.run = nil
        panel?.ignoresMouseEvents = true
        closeView?.isHidden = true
        panel?.orderOut(nil)
        if was { onRunning?(false); log?("scene end") }
    }

    /// Полноэкранное приложение: сцены не играют, идущая гаснет сразу.
    func setSuppressed(_ value: Bool) {
        suppressed = value
        if value { stop() }
    }

    var status: [String: Any] {
        var out: [String: Any] = ["running": running, "suppressed": suppressed]
        if let run = model.run, let t = elapsed {
            out["scene"] = run.kind.rawValue
            out["t"] = (t * 100).rounded() / 100
            out["phase"] = run.frame(at: t).phase
            out["target"] = lastTarget
        }
        if let p = panel {
            out["frame"] = NSStringFromRect(p.frame)
            out["ignoresMouseEvents"] = p.ignoresMouseEvents
            out["isKey"] = p.isKeyWindow
            out["isVisible"] = p.isVisible
            out["level"] = p.level.rawValue
        }
        return out
    }

    // MARK: контактный лист (без записи экрана и без показа панели)

    /// Кадры сцены в сетку: `~/.capri/tmp/scene-<name>.png` (весь кадр) и `scene-<name>-detail.png` (вокруг цели, 1×).
    @MainActor
    func sheet(_ kind: SceneKind, variant: String?, name: String) -> [URL] {
        guard var run = makeRun(kind, variant: variant, backdrop: true) else { return [] }
        run.start = Date()
        let d = SceneTimeline.duration(kind)
        var times: [Double] = (0..<16).map { Double($0) * d / 16 }
        times += Self.keyTimes(kind)
        times = Array(Set(times.map { ($0 * 100).rounded() / 100 })).sorted()
        var frames: [(Double, CGImage)] = []
        for t in times {
            let view = SceneCanvas(run: run, t: t, frame: run.frame(at: t), backdrop: true)
            let r = ImageRenderer(content: view)
            r.scale = 1
            if let im = r.cgImage { frames.append((t, im)) }
        }
        guard !frames.isEmpty else { return [] }
        // Деталь: вокруг цели/области и notch не трогаем.
        let focus = (run.geometry.area ?? run.geometry.target).insetBy(dx: -70, dy: -70)
        let crop = CGRect(x: focus.minX - run.origin.x, y: run.size.height - (focus.maxY - run.origin.y),
                          width: focus.width, height: focus.height).intersection(CGRect(origin: .zero, size: run.size)).integral
        let full = grid(frames.map { ($0.0, $0.1) }, scale: min(0.45, 640 / max(run.size.width, run.size.height)))
        let detail = grid(frames.compactMap { t, im in im.cropping(to: crop).map { (t, $0) } }, scale: 1)
        var urls: [URL] = []
        CapriPaths.ensureDir()
        for (suffix, image) in [("", full), ("-detail", detail)] {
            guard let image else { continue }
            let url = CapriPaths.tmp.appendingPathComponent("scene-\(name)\(suffix).png")
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil {
                urls.append(url)
            }
        }
        return urls
    }

    static func keyTimes(_ kind: SceneKind) -> [Double] {
        switch kind {
        case .teleport: [0.15, 0.35, 0.42, 0.55, 0.8, 4.5, 4.78, 4.9]
        case .window: [0.3, 0.45, 0.7, 0.85, 0.95, 1.5, 2.5, 7.1, 7.3, 7.5, 7.7]
        case .takeover: [0.6, 0.9, 1.3, 1.9, 2.3, 2.8, 3.4, 3.9, 4.1, 4.4]
        case .vibe: [0.3, 0.5, 1.0, 1.3, 2.0, 3.0, 6.6]
        }
    }

    private func grid(_ frames: [(Double, CGImage)], scale: CGFloat) -> CGImage? {
        guard let first = frames.first?.1 else { return nil }
        let w = CGFloat(first.width) * scale, h = CGFloat(first.height) * scale
        let cols = min(frames.count, max(1, Int(2400 / max(w, 1))), 6)
        let rows = (frames.count + cols - 1) / cols
        let label: CGFloat = 16
        let W = Int(CGFloat(cols) * (w + 4)), H = Int(CGFloat(rows) * (h + label + 4))
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        for (i, (t, im)) in frames.enumerated() {
            let c = i % cols, r = i / cols
            let x = CGFloat(c) * (w + 4), y = CGFloat(H) - CGFloat(r + 1) * (h + label + 4)
            ctx.interpolationQuality = .high
            ctx.draw(im, in: CGRect(x: x, y: y, width: w, height: h))
            NSString(string: String(format: "t=%.2f", t)).draw(at: CGPoint(x: x + 3, y: y + h + 2), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.yellow])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
