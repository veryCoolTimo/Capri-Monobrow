import AppKit
import SwiftUI
import Combine
import CapriKit

// Сцены персонажа на рабочем столе. Панель — рецепт NotchPanel: без рамки, не активирует приложение, не становится
// ключевой, прозрачная, клики проходят насквозь — кроме «горячих» точек спокойной фазы (`SceneLayout.hotspots`:
// глаза и заголовок — тянуть, «×», «📌», строки, кнопки). Есть только во время сцены; вне сцены — `orderOut`,
// TimelineView и мониторы мыши сняты, CPU ≈ 0. Полноэкранные пространства — нет (`.fullScreenAuxiliary` не ставим).
// Компьютером Capri не управляет: курсор, текст и окно — рисунок в этой панели.

final class StagePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Строка окна сессий.
struct SceneRow: Equatable {
    var key: SessionKey
    var name: String
    var detail: String
    var status: SessionStatus
    /// «3м», «1ч» — сколько в этом статусе.
    var since: String
}

/// Тексты сцены — из живых данных (обновляются во время сцены: `StageController.update(content:)`).
struct SceneContent: Equatable {
    /// Строка статуса окна: «2 ждут · votek2», «всё тихо», «♪ Artist — Track».
    var status = "всё тихо"
    /// Строки «захвата».
    var lines = ["> capri attach", "ACCESS ▮▮▮"]
    /// Окно сессий: строки и сколько ждут.
    var rows: [SceneRow] = []
    var waiting = 0
    /// Окно ответа: текст после переноса (до 6 строк) и предложение помощника.
    var answer: [String] = []
    var proposal: SceneProposal?
    /// Ответ сессии (`reply`): имя сессии и судьба ответа (nil — ждём подтверждения).
    var replyName = ""
    var delivered: Bool?
    /// Музыка: «Artist — Track» (nil — неизвестно), играет ли, что ищем («включи X») и сообщение («не нашла»).
    var track: String?
    var trackPlaying = false
    var query: String?
    var note: String?

    /// Подпись `reply`: «→ votek2 ✓» / «→ votek2 …» / «→ votek2 · не дошло».
    var caption: String {
        switch delivered {
        case true?: "→ \(replyName) ✓"
        case false?: "→ \(replyName) · не дошло"
        case nil: "→ \(replyName) …"
        }
    }
}

/// Неподтверждённое действие помощника в окне ответа.
struct SceneProposal: Equatable {
    var message: UUID
    var id: UUID
    /// «отправлю votek2: 1»
    var title: String
    /// `pending`, `sending`, `sent`, `failed`, `cancelled`.
    var state: String
    /// Текст ответа в окне обрезан — отправлять отсюда нельзя (человек не видит, что одобряет): кнопка
    /// «прочитать ↗» открывает помощника с полным текстом.
    var clipped = false
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
    /// Время таймлайна, когда сцену оборвали.
    var abortedAt: Double?
    /// Для снимков: прямоугольник «окна под панелью» (подложка).
    var backdropWindow: CGRect?
    /// Удержание (наведение, перетаскивание, «📌»).
    var clock = SceneClock()
    /// Куда сцену отнесли от исходного места.
    var offset = CGVector.zero
    /// Строк в окне сессий — по числу на старте (окно не меняет размер посреди сцены).
    var rowsCap = 0
    /// Ответ продолжает окно «думает».
    var continued = false
    /// Время таймлайна: предложение отправлено (`answer`) / ответ не дошёл (`reply`).
    var burstAt: Double?
    var failedAt: Double?
    /// Горячая точка под курсором — подсветка строки/кнопки.
    var hover: SceneHotspot.Kind?
    /// Окно музыки: смены состояния.
    var marks: [SceneMusicMark] = []
    /// ⏮ ⏯ ⏭ под глазами показаны (курсор на глазах или на кнопках).
    var controls = false

    var options: SceneOptions {
        var o = SceneOptions(text: content.status.count, lines: content.lines.map(\.count), rows: min(content.rows.count, rowsCap),
                     waiting: content.waiting, answerLines: content.answer.count, answerChars: content.answer.reduce(0) { $0 + $1.count },
                     proposal: content.proposal != nil, continued: continued, burstAt: burstAt, caption: content.caption.count,
                     failedAt: failedAt)
        o.musicMarks = marks
        o.musicKnown = content.track != nil
        o.controls = controls
        return o
    }

    /// Конец таймлайна.
    var end: Double { abortedAt.map { $0 + SceneTimeline.recallDuration } ?? SceneTimeline.duration(kind, options) }

    /// Секунды стены от начала сцены.
    func wall(_ date: Date = Date()) -> Double { date.timeIntervalSince(start) }

    /// Время таймлайна по стене.
    func time(wall w: Double) -> Double { clock.time(w) }

    /// Кадр по стене: таймлайн с удержанием; в спокойной фазе клип глаз идёт по стене (не замирает). Окно музыки
    /// считает клипы от стены само (`SceneOptions.lag`): смена состояния во время удержания начинается с клика.
    func frame(wall w: Double) -> SceneFrame {
        let t = clock.time(w)
        var o = options
        if kind == .music { o.lag = clock.lag(w) }
        var f = SceneTimeline.frame(kind, t: t, geometry: geometry, clips: clips, options: o, abortedAt: abortedAt)
        if kind != .music, abortedAt == nil, SceneTimeline.calm(kind, o)?.contains(t) == true { f.clipT += clock.lag(w) }
        return f
    }

    /// Кадр по времени таймлайна (листы, без удержания).
    func frame(at t: Double) -> SceneFrame {
        SceneTimeline.frame(kind, t: t, geometry: geometry, clips: clips, options: options, abortedAt: abortedAt)
    }

    func hotspots(wall w: Double) -> [SceneHotspot] {
        SceneLayout.hotspots(kind, t: clock.time(w), geometry: geometry, clips: clips, options: options, abortedAt: abortedAt)
    }

    /// Сцена в спокойной фазе (можно держать).
    func calm(wall w: Double) -> Bool {
        abortedAt == nil && SceneTimeline.calm(kind, options)?.contains(clock.time(w)) == true
    }
}

final class StageModel: ObservableObject {
    @Published var run: SceneRun?
}

/// Расписание кадров сцены по стене: 24 fps, в спокойной части (`SceneTimeline.calm`) — 12 fps. Панель сцены
/// большая (notch ∪ цель), каждый кадр перерисовывает её целиком — лишние кадры в покое стоят батареи.
/// Пока сцену держат, конца нет, но и кадров меньше — 4 fps (глаза дышат медленно, окно стоит); отпустили —
/// `SceneRun` меняется, и расписание пересоздаётся. Наведение и подсветка тоже меняют `SceneRun` — отклик сразу.
struct SceneSchedule: TimelineSchedule {
    var run: SceneRun
    static let frozenInterval = 1.0 / 4

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var w = max(0, startDate.timeIntervalSince(run.start))
        let o = run.options
        let frozen = run.clock.frozen
        let wallEnd = frozen ? Double.infinity : run.end + run.clock.held + 0.1
        return AnyIterator {
            guard w <= wallEnd else { return nil }
            let date = run.start.addingTimeInterval(w)
            let step = SceneTimeline.frameInterval(run.kind, t: run.clock.time(w), aborted: run.abortedAt != nil, options: o)
            w += frozen ? max(step, Self.frozenInterval) : step
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
                let w = run.wall(ctx.date)
                SceneCanvas(run: run, t: w, frame: run.frame(wall: w))
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
            c.draw(Text(StageWindows.title(run.kind) + (w.caret ? " ▮" : "  ")).font(.mono(9, .bold)).foregroundColor(pink),
                   at: CGPoint(x: bar.minX + 10, y: bar.midY), anchor: .leading)
            let x = local(SceneTimeline.closeRect(w.rect))
            c.stroke(Path(x.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink.opacity(run.hover == .close ? 1 : 0.8)), lineWidth: 1)
            if run.hover == .close { c.fill(Path(x), with: .color(pink.opacity(0.25))) }
            var cross = Path()
            cross.move(to: CGPoint(x: x.minX + 5, y: x.minY + 5)); cross.addLine(to: CGPoint(x: x.maxX - 5, y: x.maxY - 5))
            cross.move(to: CGPoint(x: x.maxX - 5, y: x.minY + 5)); cross.addLine(to: CGPoint(x: x.minX + 5, y: x.maxY - 5))
            c.stroke(cross, with: .color(pink), lineWidth: 1.4)
            StageWindows.drawPin(local(SceneTimeline.pinRect(w.rect)), pinned: run.clock.pinned, hover: run.hover == .pin, c)
            if run.kind == .window {
                // Строка статуса, печатается побуквенно; кликабельна — основное окно.
                let text = String(run.content.status.prefix(w.typed))
                let caret = w.typed < run.content.status.count || w.caret ? "▮" : " "
                if run.hover == .button("status") {
                    let sr = local(SceneTimeline.statusRect(w.rect))
                    c.fill(Path(sr), with: .color(pink.opacity(0.14)))
                    c.fill(Path(CGRect(x: sr.minX, y: sr.minY, width: 2, height: sr.height)), with: .color(Palette.acid))
                }
                c.draw(Text("> " + text + caret).font(.mono(11, .semibold)).foregroundColor(Palette.text),
                       at: CGPoint(x: r.minX + 12, y: r.maxY - 18), anchor: .leading)
            } else {
                StageWindows(run: run, window: w, local: { self.local($0) }, localPoint: { self.local($0) }, t: t).draw(c)
            }
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
        for ring in frame.rings {
            // «Отправила»: кольцо-импульс от глаз.
            let p = local(ring.center)
            let rr = 20 + 70 * ring.progress
            var c = ctx
            c.opacity = Double(1 - ring.progress)
            c.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr * 0.6, width: 2 * rr, height: 1.2 * rr)), with: .color(CapriFX.hackPink), lineWidth: 2.5)
            c.stroke(Path(ellipseIn: CGRect(x: p.x - rr * 0.7, y: p.y - rr * 0.42, width: 1.4 * rr, height: 0.84 * rr)), with: .color(Palette.acid), lineWidth: 1)
        }
        if run.controls, run.content.track != nil, !run.kind.boxed, frame.eyes != nil,
           run.abortedAt == nil, SceneTimeline.calm(run.kind, run.options)?.contains(run.clock.time(t)) == true {
            // ⏮ ⏯ ⏭ под глазами (наведение на глаза).
            let rects = SceneTimeline.eyeControls(run.geometry.target).map { ($0.id, local($0.rect)) }
            StageWindows.drawEyeControls(rects, playing: run.content.trackPlaying, hover: run.hover, ctx)
        }
        if let cap = frame.caption, cap.typed > 0 {
            StageWindows.drawCaption(String(run.content.caption.prefix(cap.typed)), full: run.content.caption.count == cap.typed,
                                     at: local(cap.anchor), failed: cap.failed, ctx)
        }
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

/// Ловит клики по горячим точкам сцены. Панель принимает мышь, только когда курсор над горячей точкой
/// (иначе `ignoresMouseEvents`), так что всё, что сюда пришло, — по горячей точке. Панель не становится ключевой
/// и не активирует Capri (`nonactivatingPanel`, `acceptsFirstMouse`).
final class StageHitView: NSView {
    weak var stage: StageController?
    private var down: SceneHotspot?
    private var last: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        down = stage?.spot(at: p)
        last = p
        // Окно появилось само под курсором: кнопки и строки нажимаются, только когда на них навели (≥ 0.4 с) —
        // клик, предназначенный приложению под сценой, не должен отправить ответ или тронуть плеер.
        if let d = down, stage?.armed(d.kind) != true { down = nil; return }
        if down?.kind == .drag { stage?.beginDrag() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard down?.kind == .drag, let l = last else { return }
        let p = NSEvent.mouseLocation
        stage?.drag(by: CGVector(dx: p.x - l.x, dy: p.y - l.y))
        last = p
    }

    override func mouseUp(with event: NSEvent) {
        defer { down = nil; last = nil }
        guard let d = down else { return }
        if d.kind == .drag { stage?.endDrag(); return }
        // Кнопка — по отпусканию над ней же (увёл мышь — передумал).
        if stage?.spot(at: NSEvent.mouseLocation)?.kind == d.kind { stage?.activate(d.kind, modifiers: event.modifierFlags) }
    }

    override func rightMouseDown(with event: NSEvent) {
        // Как у notch: общее меню с «Выйти».
        guard let menu = stage?.makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Показ сцен: панель, часы и конец сцены, горячие точки, перетаскивание, «📌», обрыв. Решения «можно ли» — у
/// `CharacterDirector`, что делают кнопки окон — у `CharacterCenter` (`onAction`).
final class StageController {
    let model = StageModel()
    private var panel: StagePanel?
    private var hitView: StageHitView?
    private var endWork: DispatchWorkItem?
    /// Мониторы мыши — только пока идёт сцена с горячими точками.
    private var monitors: [Any] = []
    private var dragging = false
    /// Над какой точкой мышь и с каких пор (для `armed`).
    private var hoverSince: (kind: SceneHotspot.Kind, at: Date)?
    static let armDelay = 0.4
    /// Глаза в notch (глобально).
    var home: () -> CGRect? = { nil }
    var screen: () -> NSScreen? = { nil }
    var content: () -> SceneContent = { SceneContent() }
    /// Сцена началась/кончилась — notch прячет/показывает свои глаза.
    var onRunning: ((Bool) -> Void)?
    /// Клик по строке/кнопке окна (кроме «×» и «📌» — их обрабатывает сцена сама).
    var onAction: ((SceneKind, SceneHotspot.Kind, NSEvent.ModifierFlags) -> Void)?
    /// Меню по правому клику (общее меню Capri с «Выйти»).
    var makeMenu: (() -> NSMenu)?
    var log: ((String) -> Void)?
    private(set) var suppressed = false
    private(set) var lastTarget = ""

    var running: Bool { model.run != nil }
    var kind: SceneKind? { model.run?.kind }
    var pinned: Bool { model.run?.clock.pinned ?? false }

    /// Время таймлайна сейчас.
    var elapsed: Double? { model.run.map { $0.time(wall: $0.wall()) } }

    // MARK: геометрия

    /// Сцена на экране notch; `variant` — `corner|window` (телепорт), `terminal|corner` (захват, ответ);
    /// `terminal` — рамка окна терминала (AppKit) для `reply`; `around` — окно, на месте которого раскрыться.
    func makeRun(_ kind: SceneKind, variant: String? = nil, backdrop: Bool = false, terminal: CGRect? = nil,
                 content given: SceneContent? = nil, around: CGRect? = nil) -> SceneRun? {
        guard let screen = screen() else { return nil }
        let visible = screen.visibleFrame
        let home = self.home() ?? CGRect(x: screen.frame.midX - 120, y: screen.frame.maxY - 22, width: 32, height: 16)
        let corner = SceneLayout.corner(visible, size: SceneTimeline.eyesSize)
        let front = Self.frontWindow(on: screen)
        let content = given ?? self.content()
        let rowsCap = max(1, min(SceneTimeline.sessionsMaxRows, content.rows.count))
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
        case .sessions, .thinking, .answer, .music:
            var o = SceneOptions(rows: rowsCap, answerLines: content.answer.count)
            o.proposal = content.proposal != nil
            let size = SceneTimeline.windowSize(kind, o)
            area = around.map { SceneLayout.resized($0, to: size, visible: visible) } ?? SceneLayout.windowForm(visible, kind: kind, options: o)
            target = SceneTimeline.eyesIn(kind, window: area!)
        case .reply:
            var w = variant == "corner" ? nil : terminal
            if w == nil, variant != "corner", backdrop {
                w = CGRect(x: visible.maxX - 860, y: visible.minY + 80, width: 760, height: 460)
            }
            if let w {
                target = SceneLayout.atTerminal(w, visible: visible); lastTarget = "terminal"; backdropWindow = w
            }
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
        guard let (origin, size) = Self.panelFrame(g, screen: screen) else { return nil }
        return SceneRun(kind: kind, start: Date(), geometry: g, origin: origin, size: size, clips: SceneArt.clips, content: content,
                        abortedAt: nil, backdropWindow: backdrop ? backdropWindow : nil, rowsCap: rowsCap)
    }

    /// Панель — всё, что сцена может занять, в пределах экрана.
    static func panelFrame(_ g: SceneGeometry, screen: NSScreen) -> (CGPoint, CGSize)? {
        let bounds = g.bounds.intersection(screen.frame).integral
        guard !bounds.isNull, bounds.width > 0 else { return nil }
        return (bounds.origin, bounds.size)
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
    func play(_ kind: SceneKind, variant: String? = nil, terminal: CGRect? = nil, content: SceneContent? = nil, around: CGRect? = nil) -> Bool {
        guard !suppressed else { log?("scene \(kind.rawValue): skip fullscreen"); return false }
        stop()
        guard let run = makeRun(kind, variant: variant, terminal: terminal, content: content, around: around) else {
            log?("scene \(kind.rawValue): no screen"); return false
        }
        show(run)
        log?("scene \(kind.rawValue) → \(lastTarget) frame=\(NSStringFromRect(panel?.frame ?? .zero))")
        return true
    }

    /// «Думает» → ответ в том же окне (где бы оно ни стояло): глитч-переход вместо прилёта.
    @discardableResult
    func morph(to kind: SceneKind, content: SceneContent) -> Bool {
        guard let old = model.run, old.abortedAt == nil, let area = old.geometry.area else { return play(kind, content: content) }
        guard var run = makeRun(kind, content: content, around: area) else { return false }
        run.continued = true
        run.geometry.home = old.geometry.home
        endWork?.cancel()
        removeMonitors()
        model.run = nil
        show(run)
        log?("scene \(old.kind.rawValue) → \(kind.rawValue) (в том же окне)")
        return true
    }

    private func show(_ run: SceneRun) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(CGRect(origin: run.origin, size: run.size), display: false)
        setIgnores(true)
        model.run = run
        panel.orderFrontRegardless()
        onRunning?(true)
        reschedule()
        if run.kind != .takeover { installMonitors() }
        // Курсор уже может стоять там, где появится кнопка: проверить в начале спокойной фазы.
        if let calm = SceneTimeline.calm(run.kind, run.options) {
            DispatchQueue.main.asyncAfter(deadline: .now() + calm.lowerBound + 0.02) { [weak self] in self?.track() }
        }
    }

    private func makePanel() -> StagePanel {
        let p = StagePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Над notch (mainMenu + 3): глаза уходят из notch и возвращаются в него. Клики проходят насквозь, кроме
        // горячих точек.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.acceptsMouseMovedEvents = true
        p.becomesKeyOnlyIfNeeded = true
        p.animationBehavior = .none
        let container = NSView()
        let host = NSHostingView(rootView: SceneView(model: model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        let hit = StageHitView()
        hit.stage = self
        hit.autoresizingMask = [.width, .height]
        container.addSubview(hit)
        hitView = hit
        p.contentView = container
        return p
    }

    private func setIgnores(_ value: Bool) {
        if let panel, panel.ignoresMouseEvents != value { panel.ignoresMouseEvents = value }
    }

    /// Конец сцены по часам: идёт — таймер на остаток; стоит — проверка, когда кончится удержание.
    private func reschedule() {
        endWork?.cancel()
        endWork = nil
        guard var run = model.run else { return }
        let w = run.wall()
        if run.clock.update(w) { model.run = run }
        run = model.run!
        let delay: Double
        let finish: Bool
        if let rem = run.clock.remaining(w, end: run.end) {
            delay = rem; finish = true
        } else if let next = run.clock.nextCheck() {
            delay = next - w; finish = false
        } else {
            return    // держат мышью — придёт событие мыши
        }
        let work = DispatchWorkItem { [weak self] in
            if finish { self?.stop() } else { self?.reschedule() }
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, delay) + 0.05, execute: work)
    }

    // MARK: мышь

    /// Мониторы движения мыши (как у notch: разрешений не требуют) — только на время сцены.
    private func installMonitors() {
        removeMonitors()
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in self?.track() }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] e in self?.track(); return e }) { monitors.append(m) }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
    }

    /// Можно ли нажать: «×», «📌» и перетаскивание — сразу; кнопки и строки — после `armDelay` наведения.
    func armed(_ kind: SceneHotspot.Kind) -> Bool {
        switch kind {
        case .close, .pin, .drag: return true
        default:
            guard let h = hoverSince, h.kind == kind else { return false }
            return Date().timeIntervalSince(h.at) >= Self.armDelay
        }
    }

    /// Горячая точка под точкой `p` сейчас.
    func spot(at p: CGPoint) -> SceneHotspot? {
        guard let run = model.run else { return nil }
        return SceneLayout.hit(run.hotspots(wall: run.wall()), p)
    }

    static func isMusicButton(_ k: SceneHotspot.Kind) -> Bool {
        if case .button(let id) = k { return MusicCommand(button: id) != nil }
        return false
    }

    /// Курсор сдвинулся: панель ловит мышь только над горячей точкой; наведение держит сцену. Наведение на глаза
    /// (не в окне) показывает под ними ⏮ ⏯ ⏭, если музыка известна.
    private func track() {
        guard var run = model.run, !dragging, run.abortedAt == nil else { return }
        let w = run.wall()
        let p = NSEvent.mouseLocation
        var over = SceneLayout.hit(run.hotspots(wall: w), p)
        var controlsChanged = false
        if !run.kind.boxed, run.content.track != nil {
            let want = over.map { $0.kind == .drag || Self.isMusicButton($0.kind) } ?? false
            if want != run.controls {
                run.controls = want
                controlsChanged = true
                over = SceneLayout.hit(run.hotspots(wall: w), p)
            }
        }
        setIgnores(over == nil)
        if over?.kind != hoverSince?.kind { hoverSince = over.map { ($0.kind, Date()) } }
        let holding = over != nil
        guard controlsChanged || holding != run.clock.holding || over?.kind != run.hover else { return }
        if holding != run.clock.holding { run.clock.hold(holding, wall: w, calm: run.calm(wall: w)) }
        run.hover = over?.kind
        model.run = run
        reschedule()
    }

    /// Горячих точек стало меньше (строки, кнопки) под неподвижной мышью: пересчитать, ловит ли панель клик —
    /// иначе клик по уже пустому месту проглотит `StageHitView`. Наведение и кнопки не трогаем (это `track`).
    private func refreshIgnores() {
        guard let run = model.run, !dragging, run.abortedAt == nil else { return }
        setIgnores(SceneLayout.hit(run.hotspots(wall: run.wall()), NSEvent.mouseLocation) == nil)
    }

    func beginDrag() {
        guard var run = model.run else { return }
        dragging = true
        let w = run.wall()
        run.clock.hold(true, wall: w, calm: run.calm(wall: w))
        run.hover = .drag
        model.run = run
        reschedule()
    }

    /// Перетаскивание: цель и окно едут (не за экран), панель пересчитывается.
    func drag(by d: CGVector) {
        // После обрыва `StageHitView` ещё шлёт перетаскивание — сцена уже летит домой, не двигаем.
        guard dragging, var run = model.run, run.abortedAt == nil, let screen = screen() else { return }
        let before = run.geometry.area ?? run.geometry.target
        run.geometry = run.geometry.moved(by: d)
        let after = run.geometry.area ?? run.geometry.target
        run.offset.dx += after.minX - before.minX
        run.offset.dy += after.minY - before.minY
        guard let (origin, size) = Self.panelFrame(run.geometry, screen: screen) else { return }
        run.origin = origin
        run.size = size
        model.run = run
        panel?.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        guard var run = model.run else { return }
        run.clock.hold(false, wall: run.wall(), calm: false)
        model.run = run
        log?("scene drag → offset \(Int(run.offset.dx)),\(Int(run.offset.dy))")
        track()
        reschedule()
    }

    /// Клик по горячей точке.
    func activate(_ kind: SceneHotspot.Kind, modifiers: NSEvent.ModifierFlags = []) {
        guard var run = model.run else { return }
        switch kind {
        case .close:
            log?("scene: × clicked")
            stop()
        case .pin:
            let w = run.wall()
            run.clock.pin(!run.clock.pinned, wall: w, calm: run.calm(wall: w))
            model.run = run
            log?("scene pin \(run.clock.pinned)")
            reschedule()
        case .drag:
            break
        default:
            log?("scene \(run.kind.rawValue): click \(kind)")
            onAction?(run.kind, kind, modifiers)
        }
    }

    /// Живые данные во время сцены (строки сессий, состояние предложения, «доставлено»).
    func update(content: SceneContent) {
        guard var run = model.run, run.content != content else { return }
        run.content = content
        model.run = run
        reschedule()
        refreshIgnores()
    }

    /// ⏮ ⏯ ⏭ под глазами без мыши (`stage controls on|off`).
    func setControls(_ on: Bool) {
        guard var run = model.run, run.controls != on else { return }
        run.controls = on
        model.run = run
        refreshIgnores()
    }

    /// Окно музыки: новое состояние (ищет, играет, пауза, не вышло). До конца прилёта — с конца прилёта.
    func mark(music state: SceneMusicState) {
        guard var run = model.run, run.kind == .music, run.abortedAt == nil, run.marks.last?.state != state else { return }
        let w = run.wall()
        let t = run.clock.time(w)
        let start = SceneTimeline.calm(.music, run.options)?.lowerBound ?? 0
        let shift = max(0, start - t)
        run.marks.append(SceneMusicMark(t: t + shift, wall: w + shift, state: state))
        model.run = run
        log?("scene music: \(state.rawValue)")
        reschedule()
        refreshIgnores()
    }

    /// Отметить момент таймлайна: предложение отправлено (`answer`) / ответ не дошёл (`reply`).
    func mark(burst: Bool = false, failed: Bool = false) {
        guard var run = model.run, let t = elapsed else { return }
        if burst, run.burstAt == nil { run.burstAt = t }
        if failed, run.failedAt == nil { run.failedAt = t }
        model.run = run
    }

    /// Обрыв (кто-то ждёт ответа, notch раскрыли): молния домой за 0.35 с. Держание и «📌» снимаются.
    func abort(_ why: String) {
        guard var run = model.run, run.abortedAt == nil else { return }
        let w = run.wall()
        run.clock.release(w)
        let t = run.clock.time(w)
        guard t < SceneTimeline.duration(run.kind, run.options) - SceneTimeline.recallDuration else { return }
        run.abortedAt = t
        run.hover = nil
        dragging = false
        model.run = run
        setIgnores(true)
        removeMonitors()
        log?("scene abort (\(why)) at \(String(format: "%.2f", t))")
        reschedule()
    }

    /// Сразу убрать панель.
    func stop() {
        endWork?.cancel(); endWork = nil
        removeMonitors()
        dragging = false
        let was = model.run != nil
        model.run = nil
        setIgnores(true)
        panel?.orderOut(nil)
        if was { onRunning?(false); log?("scene end") }
    }

    /// Полноэкранное приложение: сцены не играют, идущая гаснет сразу.
    func setSuppressed(_ value: Bool) {
        suppressed = value
        if value { stop() }
    }

    var status: [String: Any] {
        var out: [String: Any] = ["running": running, "suppressed": suppressed, "tracking": !monitors.isEmpty]
        if let run = model.run {
            let w = run.wall()
            let t = run.time(wall: w)
            out["scene"] = run.kind.rawValue
            out["t"] = (t * 100).rounded() / 100
            out["wall"] = (w * 100).rounded() / 100
            out["phase"] = run.frame(wall: w).phase
            out["clip"] = run.frame(wall: w).clip
            out["target"] = lastTarget
            out["offset"] = [Int(run.offset.dx), Int(run.offset.dy)]
            out["held"] = run.clock.frozen
            out["pinned"] = run.clock.pinned
            let spots = run.hotspots(wall: w)
            out["hotspots"] = spots.count
            out["spots"] = spots.map { s in "\(s.kind) \(Int(s.rect.minX)),\(Int(s.rect.minY)) \(Int(s.rect.width))x\(Int(s.rect.height))" }
            out["rows"] = run.content.rows.count
            out["answerLines"] = run.content.answer.count
            out["caption"] = run.content.caption.count
            out["controls"] = run.controls
            if run.kind == .music {
                out["music"] = run.marks.map { "\($0.state.rawValue)@\((($0.t * 10).rounded() / 10))" }
                out["musicState"] = SceneTimeline.musicState(at: t, run.marks).state.rawValue
            }
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
    func sheet(_ kind: SceneKind, variant: String?, name: String, content: SceneContent? = nil) -> [URL] {
        guard var run = makeRun(kind, variant: variant, backdrop: true, content: content) else { return [] }
        run.start = Date()
        // Ответ терминалу на листе — «доставлено».
        if kind == .reply, run.content.delivered == nil { run.content.delivered = variant != "fail" }
        if kind == .reply, variant == "fail" { run.failedAt = 2.0 }
        if kind == .answer, variant == "sent" { run.burstAt = 4.0 }
        if kind == .music {
            // Лист: ищет → (играет, пауза, снова играет) / не нашла / нужен ключ.
            if run.content.track == nil { run.content.track = "Test Artist — Test Track" }
            if run.content.query == nil { run.content.query = "test track" }
            run.content.trackPlaying = true
            run.marks = [SceneMusicMark(t: 1.0, state: .searching)]
            switch variant {
            case "fail": run.marks.append(SceneMusicMark(t: 2.5, state: .failed))
            case "search":
                run.content.note = "нужен ключ Spotify"
                run.marks.append(SceneMusicMark(t: 2.5, state: .info))
            default:
                run.marks += [SceneMusicMark(t: 2.5, state: .playing), SceneMusicMark(t: 4.5, state: .paused),
                              SceneMusicMark(t: 5.2, state: .playing)]
            }
        }
        if variant == "controls", !kind.boxed {
            // Наведение на глаза: ⏮ ⏯ ⏭ под ними.
            if run.content.track == nil { run.content.track = "Test Artist — Test Track" }
            run.content.trackPlaying = true
            run.controls = true
            run.hover = .button("toggle")
        }
        let d = SceneTimeline.duration(kind, run.options)
        // Длинные сцены («думает» — минута): первые 10 с и уход.
        let span = min(d, 10)
        var times: [Double] = (0..<16).map { Double($0) * span / 16 }
        if d > span { times += [d - 0.85, d - 0.6, d - 0.35, d - 0.1] }
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
        var focus = (run.geometry.area ?? run.geometry.target).insetBy(dx: -70, dy: -70)
        // Подпись `reply` — слева от глаз.
        if kind == .reply { focus = focus.union(focus.offsetBy(dx: -220, dy: 0)) }
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
        case .sessions: [0.3, 0.7, 0.9, 1.2, 1.5, 3.0, 7.3, 7.5, 7.7]
        case .thinking: [0.7, 0.9, 1.2, 1.5, 2.6, 3.4]
        case .answer: [0.7, 0.9, 1.2, 2.0, 4.2, 4.6]
        case .reply: [0.15, 0.4, 0.7, 1.0, 1.2, 1.7, 2.2, 3.0, 3.5, 3.8]
        case .music: [0.7, 0.9, 1.2, 2.6, 2.8, 3.1, 4.6, 4.8, 5.4, 6.2]
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
