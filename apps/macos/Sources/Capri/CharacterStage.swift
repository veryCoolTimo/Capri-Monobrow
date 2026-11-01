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
    /// «На окне»: реплика в пузыре.
    var bubble: String?
    /// Терминал: все реплики сцены по порядку (пузырь `say` берёт свою).
    var says: [String] = []

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
    /// Стена, когда сменилась горячая точка под курсором (окно сессий: наезд в глаз над строкой).
    var hoverAt = 0.0
    /// Переходы сцены (общая библиотека `Transitions`): вход у цели, уход от неё, зерно, Reduce Motion.
    var enter: TransitionKind = .glitchBars
    var exit: TransitionKind = .glitchBars
    var seed = 0
    var reduceMotion = false
    /// Вайб: смены трека (время таймлайна) — глитч 1.
    var glitchMarks: [Double] = []
    /// «На окне»: экран окна (если не экран notch), мини-прыжок (откуда и когда), держится, пока окно тащат.
    var screenFrame: CGRect?
    var hopAt: Double?
    var hopFrom: CGRect?
    var perchHold = false
    /// Снимок: окна поверх того, на котором сидит.
    var backdropAbove: [CGRect] = []
    /// «На окне» терминала: смотрит за сессией (реплики, конец, злорадство).
    var watch: SceneWatch?
    /// Оборвали, потому что ждут сразу несколько сессий: мини-маска — рой глаз перед молнией домой.
    var overload = false

    var options: SceneOptions {
        var o = SceneOptions(text: content.status.count, lines: content.lines.map(\.count), rows: min(content.rows.count, rowsCap),
                     waiting: content.waiting, answerLines: content.answer.count, answerChars: content.answer.reduce(0) { $0 + $1.count },
                     proposal: content.proposal != nil, continued: continued, burstAt: burstAt, caption: content.caption.count,
                     failedAt: failedAt)
        o.musicMarks = marks
        o.musicKnown = content.track != nil
        o.controls = controls
        if case .row(let i)? = hover { o.hoverRow = i }
        o.hoverAt = hoverAt
        o.enter = enter
        o.exit = exit
        o.seed = seed
        o.reduceMotion = reduceMotion
        o.glitchMarks = glitchMarks
        o.perchChars = content.bubble?.count ?? 0
        o.hopAt = hopAt
        o.hopFrom = hopFrom
        o.perchHold = perchHold
        o.watch = watch
        o.overload = overload
        return o
    }

    /// Конец таймлайна.
    var end: Double { abortedAt.map { $0 + SceneTimeline.recallLen(kind, options) } ?? SceneTimeline.duration(kind, options) }

    /// Секунды стены от начала сцены.
    func wall(_ date: Date = Date()) -> Double { date.timeIntervalSince(start) }

    /// Время таймлайна по стене.
    func time(wall w: Double) -> Double { clock.time(w) }

    /// Кадр по стене: таймлайн с удержанием; в спокойной фазе клип глаз идёт по стене (не замирает). Окно музыки
    /// считает клипы от стены само (`SceneOptions.lag`): смена состояния во время удержания начинается с клика.
    func frame(wall w: Double) -> SceneFrame {
        let t = clock.time(w)
        var o = options
        o.lag = clock.lag(w)
        var f = SceneTimeline.frame(kind, t: t, geometry: geometry, clips: clips, options: o, abortedAt: abortedAt)
        if !f.wallClock, kind != .perch, abortedAt == nil, SceneTimeline.calm(kind, o)?.contains(t) == true { f.clipT += clock.lag(w) }
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
/// Пока сцену держат, конца нет, но и кадров меньше — 4 fps (глаза дышат медленно, окно стоит); у крупного лица
/// (окна, `reply`: клип и движение идут по стене) — те же 12 fps, иначе оно дёргается. Отпустили — `SceneRun`
/// меняется, и расписание пересоздаётся. Наведение и подсветка тоже меняют `SceneRun` — отклик сразу.
struct SceneSchedule: TimelineSchedule {
    var run: SceneRun
    static let frozenInterval = 1.0 / 4

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var w = max(0, startDate.timeIntervalSince(run.start))
        let o = run.options
        // Крупное лицо живёт по стене — замедлять нечего.
        let frozen = run.clock.frozen
        let slow = frozen && !SceneTimeline.usesFace(run.kind)
        let wallEnd = frozen ? Double.infinity : run.end + run.clock.held + 0.1
        return AnyIterator {
            guard w <= wallEnd else { return nil }
            let date = run.start.addingTimeInterval(w)
            let step = SceneTimeline.frameInterval(run.kind, t: run.clock.time(w), aborted: run.abortedAt != nil, options: o)
            // Секунду после смены наведения (наезд в глаз над строкой) — 12 fps и при удержании.
            let fresh = run.hoverAt > 0 && w - run.hoverAt < 1
            // «На окне» стоит под курсором — картинка не меняется вовсе: кадр раз в секунду (подхватить отпускание).
            w += slow && run.kind == .perch ? 1 : slow && !fresh ? max(step, Self.frozenInterval) : step
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
                let _ = StageController.countFrame()
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
            // Подложка есть только у окон и захвата — без неё не держим лишний слой во весь размер панели.
            if frame.window != nil || frame.takeover != nil || frame.smear != nil { Canvas { ctx, _ in drawBack(ctx) } }
            if let fx = frame.fx, !fx.plain {
                // Переход: глаза полосами/столбцами (символ Canvas рисуется по кускам) или их нет вовсе.
                if let at = fx.rect {
                    let r = local(at)
                    Canvas { ctx, _ in
                        guard let eyes = ctx.resolveSymbol(id: 0) else { return }
                        TransitionArt.drawContent(fx, symbol: eyes, in: r, squash: frame.squash, ctx)
                    } symbols: {
                        SceneEyes(frame: frame, t: t).frame(width: r.width, height: r.height).tag(0)
                    }
                }
            } else if let e = frame.eyes, let pose = frame.rig {
                // Мини-маска: руки, волосы и «z» выходят за полосу глаз — Canvas с запасом.
                let r = local(e)
                let pad = RigCanvas.margin(r.size)
                RigCanvas(pose: pose, glitch: frame.glitch, pad: pad)
                    .frame(width: r.width + 2 * pad.width, height: r.height + 2 * pad.height)
                    .scaleEffect(x: 1 + (1 - frame.squash) * 0.25, y: max(0.02, frame.squash))
                    .position(x: r.midX, y: r.midY)
            } else if let e = frame.eyes {
                let r = local(e)
                SceneEyes(frame: frame, t: t)
                    .frame(width: r.width, height: r.height)
                    // Лицо в окне не шире рамки; глаза на столе при сплющивании чуть раздаются вширь.
                    .scaleEffect(x: frame.face != nil ? 1 : 1 + (1 - frame.squash) * 0.25, y: max(0.02, frame.squash))
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
            // Кнопки окна — их Capri не закрывает.
            for (k, c) in [Color.red, .yellow, .green].enumerated() {
                ctx.fill(Path(ellipseIn: CGRect(x: r.minX + 9 + CGFloat(k) * 20, y: r.minY + 7, width: 12, height: 12)), with: .color(c.opacity(0.8)))
            }
        }
        for a in run.backdropAbove {
            let r = local(a)
            ctx.fill(Path(roundedRect: r, cornerRadius: 10), with: .color(Color(white: 0.24)))
            ctx.stroke(Path(roundedRect: r, cornerRadius: 10), with: .color(Color(white: 0.4)), lineWidth: 1)
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
        if let m = frame.smear { drawSmear(m, ctx) }
    }

    /// Капли у верхнего края окна терминала: малиновые столбцы волос с фиолетовой тенью со сдвигом (как игла молнии),
    /// скруглённым низом, полупрозрачные, в узкой полосе под местом посадки. Только рисунок поверх чужого окна.
    private func drawSmear(_ m: WindowSmear, _ ctx: GraphicsContext) {
        let r = local(m.rect)
        var c = ctx
        c.opacity = Double(m.alpha)
        // Только по самому окну (капли за край не вылезают — иначе висят «таблетками» в воздухе).
        c.clip(to: Path(roundedRect: local(m.clip), cornerRadius: 10))
        if m.tint > 0 { c.fill(Path(r), with: .color(BiblePalette.hair.opacity(Double(m.tint)))) }
        var shade = Path(), red = Path(), dark = Path()
        for (i, col) in m.columns.enumerated() {
            let x = r.minX + col.x * r.width
            let w = max(1, col.w * r.width + 0.5)
            let top = r.minY + col.top * r.height
            let bottom = r.minY + col.bottom * r.height
            // Верх — прямой срез, низ — капля (полуэллипс не выше 7 pt).
            let cap = min(w * 0.45, 7, max(0, bottom - top) / 2)
            var p = Path(CGRect(x: x, y: top, width: w, height: max(0, bottom - top - cap)))
            if cap > 0.5 { p.addEllipse(in: CGRect(x: x, y: bottom - 2 * cap, width: w, height: 2 * cap)) }
            // Соседние столбцы чуть разного тона — видно, что стекают столбцами, а не сплошной плашкой.
            if TickNoise.unit(i, 1365) < 0.4 { dark.addPath(p) } else { red.addPath(p) }
            shade.addPath(p.offsetBy(dx: 2, dy: 3))
        }
        c.fill(shade, with: .color(Palette.violet.opacity(0.75)))
        c.fill(red, with: .color(BiblePalette.hair))
        c.fill(dark, with: .color(Color(red: 0xC8 / 255, green: 0x08 / 255, blue: 0x3A / 255)))
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
        }
    }

    /// Поверх лица: подписи на полосе-градиенте, строки и кнопки, рамка и уголки HUD (лицо закрывает тело окна).
    private func drawWindowFront(_ w: SceneWindow, _ ctx: GraphicsContext) {
        guard w.open >= 1, w.chrome else { return }
        let r = local(w.rect)
        let pink = CapriFX.hackPink
        var c = ctx
        if w.melt > 0 { c.opacity = Double(max(0, 1 - w.melt * 1.4)) }
        StageWindows(run: run, window: w, local: { self.local($0) }, localPoint: { self.local($0) }, t: t).draw(c)
        c.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink), lineWidth: 1)
        // Уголки-скобки HUD.
        var ticks = Path()
        for (px, py, sx, sy) in [(r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
            ticks.move(to: CGPoint(x: px + 4 * sx, y: py + 10 * sy)); ticks.addLine(to: CGPoint(x: px + 4 * sx, y: py + 4 * sy))
            ticks.addLine(to: CGPoint(x: px + 10 * sx, y: py + 4 * sy))
        }
        c.stroke(ticks, with: .color(pink.opacity(0.7)), lineWidth: 1)
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
        if let w = frame.window { drawWindowFront(w, ctx) }
        if let fx = frame.fx {
            if let rb = fx.ribbon { TransitionArt.drawRibbon(rb, map: { self.local($0) }, ctx) }
            if let f = fx.flash { TransitionArt.drawFlash(f, in: local(f.rect), ctx) }
            if let b = fx.bolt { TransitionArt.drawBolt(b, map: { self.local($0) }, width: 3, ctx) }
        }
        if let b = frame.bolt { drawBolt(b, ctx, width: 3) }
        if frame.flash > 0, let at = frame.flashAt {
            // Вспышка 2 кадра сплошным цветом (волосы или маска) с белым ядром — «вошла» в точку.
            let p = local(at), f = Double(frame.flash)
            let r: CGFloat = 18 + 22 * (1 - frame.flash)
            var c = ctx
            c.opacity = f
            let box = CGRect(x: p.x - r * 1.2, y: p.y - r * 0.8, width: r * 2.4, height: r * 1.6)
            c.fill(TransitionArt.burst(seed: run.seed &+ Int(t * 24), in: box), with: .color(BiblePalette.flash(frame.flashTint)))
            c.fill(TransitionArt.burst(seed: run.seed &+ 5, in: box.insetBy(dx: r * 0.75, dy: r * 0.5)), with: .color(.white))
            c.stroke(TransitionArt.burst(seed: run.seed &+ Int(t * 24), in: box), with: .color(BiblePalette.bolt), lineWidth: 1.5)
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
        if run.controls, run.content.track != nil, !run.kind.boxed, run.kind != .perch, frame.eyes != nil,
           run.abortedAt == nil, SceneTimeline.calm(run.kind, run.options)?.contains(run.clock.time(t)) == true {
            // ⏮ ⏯ ⏭ под глазами (наведение на глаза).
            let rects = SceneTimeline.eyeControls(run.geometry.target).map { ($0.id, local($0.rect)) }
            StageWindows.drawEyeControls(rects, playing: run.content.trackPlaying, hover: run.hover, ctx)
        }
        if let b = frame.bubble, let text = b.say < run.content.says.count ? run.content.says[b.say] : run.content.bubble {
            drawBubble(b, text: text, ctx)
        }
        if let cap = frame.caption, cap.typed > 0 {
            StageWindows.drawCaption(String(run.content.caption.prefix(cap.typed)), full: run.content.caption.count == cap.typed,
                                     at: local(cap.anchor), failed: cap.failed, ctx)
        }
        for n in frame.notes {
            var c = ctx
            c.opacity = Double(n.alpha)
            // Нота — контуром (не текстом: набор текста каждый кадр был самым дорогим в покое вайба).
            let path = Self.notePath(n.glyph % 3, at: local(n.center))
            c.fill(path.offsetBy(dx: 1.5, dy: 1.5), with: .color(Palette.violet))
            c.fill(path, with: .color(CapriFX.hackPink))
        }
    }

    /// Пузырь реплики: тёмная плашка, розовая рамка 1 px с уголком к глазам, моно 11 pt с кареткой. Проступает и
    /// рассыпается полосами со сдвигом.
    private func drawBubble(_ b: SceneBubble, text: String, _ ctx: GraphicsContext) {
        let r = local(b.rect)
        let pink = CapriFX.hackPink
        let typed = String(text.prefix(b.typed)) + (b.caret ? "▮" : "")
        func body(_ c: GraphicsContext, dx: CGFloat) {
            let box = r.offsetBy(dx: dx, dy: 0)
            c.fill(Path(box), with: .color(Color(red: 0.03, green: 0.02, blue: 0.05).opacity(0.94)))
            c.stroke(Path(box.insetBy(dx: 0.5, dy: 0.5)), with: .color(pink), lineWidth: 1)
            c.fill(Path(CGRect(x: box.minX + 1, y: box.minY + 1, width: 2, height: box.height - 2)), with: .color(Palette.acid))
            c.draw(Text(typed).font(.mono(11, .semibold)).foregroundColor(Palette.text),
                   at: CGPoint(x: box.minX + 10, y: box.midY), anchor: .leading)
        }
        if b.glitch {
            // Полосы со сдвигом и RGB-разнос: три горизонтальных среза пузыря.
            let tick = Int(t * 24)
            for k in 0..<3 {
                var c = ctx
                let band = CGRect(x: r.minX - 20, y: r.minY + r.height * CGFloat(k) / 3, width: r.width + 40, height: r.height / 3 + 0.5)
                c.clip(to: Path(band))
                let dx = (CGFloat(TickNoise.unit(k, 77 + tick)) - 0.5) * 18
                c.opacity = 0.55
                c.fill(Path(r.offsetBy(dx: dx - 3, dy: 0)), with: .color(Palette.violet))
                c.opacity = 1
                body(c, dx: dx)
            }
        } else {
            body(ctx, dx: 0)
        }
    }

    /// Нота ♪ (0), ♫ (1), ♬ (2) контуром ≈ 22 pt вокруг `c` (координаты панели, сверху вниз).
    static func notePath(_ glyph: Int, at c: CGPoint) -> Path {
        var p = Path()
        func head(_ x: CGFloat, _ y: CGFloat) {
            p.addPath(Path(ellipseIn: CGRect(x: -4.5, y: -3.2, width: 9, height: 6.4))
                .applying(CGAffineTransform(rotationAngle: -0.45).concatenating(CGAffineTransform(translationX: x, y: y))))
        }
        let base = c.y + 8
        switch glyph {
        case 0:
            head(c.x - 3, base)
            p.addRect(CGRect(x: c.x + 0.6, y: base - 17, width: 2, height: 17))
            p.move(to: CGPoint(x: c.x + 2.6, y: base - 17))
            p.addQuadCurve(to: CGPoint(x: c.x + 7, y: base - 6), control: CGPoint(x: c.x + 9, y: base - 12))
            p.addLine(to: CGPoint(x: c.x + 2.6, y: base - 12))
            p.closeSubpath()
        default:
            head(c.x - 7, base)
            head(c.x + 5, base - 3)
            p.addRect(CGRect(x: c.x - 3.4, y: base - 17, width: 2, height: 17))
            p.addRect(CGRect(x: c.x + 8.6, y: base - 20, width: 2, height: 17))
            var beam = Path()
            beam.addLines([CGPoint(x: c.x - 3.4, y: base - 17), CGPoint(x: c.x + 10.6, y: base - 20),
                           CGPoint(x: c.x + 10.6, y: base - 16), CGPoint(x: c.x - 3.4, y: base - 13)])
            beam.closeSubpath()
            p.addPath(beam)
            if glyph == 2 { p.addPath(beam.offsetBy(dx: 0, dy: 6)) }
        }
        return p
    }

    /// Перелёт: розовая игольчатая молния (`TransitionArt.drawBolt`, концы — из общей библиотеки), кипит вместе с `seed`.
    private func drawBolt(_ b: SceneBolt, _ ctx: GraphicsContext, width: CGFloat) {
        guard let bolt = Transitions.bolt(from: b.from, to: b.to, seed: run.seed &+ b.seed &* 7, reach: b.reach) else { return }
        TransitionArt.drawBolt(bolt, map: { self.local($0) }, width: width, ctx)
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
            // Тонкая розовая молния вдоль верхнего или правого края (точки уже локальные).
            let top = seed % 2 == 0
            let from = top ? CGPoint(x: a.minX + a.width * 0.1, y: a.minY + 2) : CGPoint(x: a.maxX - 2, y: a.minY + a.height * 0.1)
            let to = top ? CGPoint(x: a.minX + a.width * 0.7, y: a.minY + 4) : CGPoint(x: a.maxX - 4, y: a.minY + a.height * 0.8)
            if let bolt = Transitions.bolt(from: from, to: to, seed: seed &* 13 &+ Int(t * 12)) {
                TransitionArt.drawBolt(bolt, map: { $0 }, width: 1.4, ctx)
            }
        }
    }
}

/// Глаза сцены: клип сериала (или встроенный кадр) с глитчем.
struct SceneEyes: View {
    var frame: SceneFrame
    var t: Double

    var body: some View {
        let tick = Int(t * CapriFace.fps)
        if let pose = frame.rig {
            RigCanvas(pose: pose, glitch: frame.glitch)
        } else {
            shot(tick)
        }
    }

    private func shot(_ tick: Int) -> some View {
        CapriShotView(image: SceneArt.image(frame.clip, t: frame.clipT, mode: frame.clipMode),
                      glitch: frame.glitch > 0 ? CapriFX.make(level: frame.glitch, tick: tick, strength: 1) : nil,
                      bolt: nil, fill: frame.face != nil, face: frame.face)
    }
}

/// Рисунки для сцен: клипы сериала из `~/.capri/art/eyes`, иначе встроенные кадры.
enum SceneArt {
    /// Какие клипы есть (для фолбэков таймлайна).
    static var clips: Set<String> {
        if let show = ShowArt.shared { return Set(show.clips.keys) }
        return []
    }

    static func image(_ clip: String, t: Double, mode: FrameClip.Mode) -> NSImage? {
        if let show = ShowArt.shared { return show.image(clip: clip, t: t, mode: mode) }
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
    /// Сжать/разжать панель на границе спокойной фазы.
    private var compactWork: DispatchWorkItem?
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
    /// `--debug-control`: живые сцены на столе не играют (агенты проверяют без Тимофея — живая сцена поверх его окон
    /// выглядит как «появилась без причины»); листы `scene sheet` — офскрин, работают. `scene live on` — разрешить.
    var offscreenOnly = false
    private(set) var lastTarget = ""
    /// Сцена доиграла до конца (не обрыв, не «×») — вайб после этого кивает в notch.
    var onFinished: ((SceneKind) -> Void)?
    /// Сцена убрана с экрана (любым путём) — «на окне» снимает опрос окна и монитор мыши.
    var onEnded: ((SceneKind) -> Void)?
    /// Прошлые виды входа/выхода — два подряд одинаковыми не бывают.
    private var lastEnter: TransitionKind?
    private var lastExit: TransitionKind?
    private var fxCount = 0

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
            target = SceneTimeline.faceIn(.window, window: area!)
        case .sessions, .thinking, .answer, .music:
            var o = SceneOptions(rows: rowsCap, answerLines: content.answer.count)
            o.proposal = content.proposal != nil
            let size = SceneTimeline.windowSize(kind, o)
            area = around.map { SceneLayout.resized($0, to: size, visible: visible) } ?? SceneLayout.windowForm(visible, kind: kind, options: o)
            target = SceneTimeline.faceIn(kind, window: area!)
        case .reply:
            // Крупное лицо 200×125 вместо полосы глаз (у терминала без места сверху — полоса глаз, `atTerminal`).
            target = SceneLayout.corner(visible, size: SceneTimeline.replySize)
            var w = variant == "corner" ? nil : terminal
            if w == nil, variant != "corner", backdrop {
                w = CGRect(x: visible.maxX - 860, y: visible.minY + 80, width: 760, height: 460)
            }
            if let w {
                target = SceneLayout.atTerminal(w, visible: visible, size: SceneTimeline.replySize); lastTarget = "terminal"; backdropWindow = w
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
        case .perch:
            // Живой показ — `perch(_:)`; здесь — лист и отладка: муляж окна посреди экрана (варианты — разные края).
            guard backdrop || variant?.hasPrefix("mock") == true else { lastTarget = "none"; return nil }
            if variant?.hasPrefix("watch") == true { return watchMock(variant, home: home, visible: visible, screen: screen.frame, content: content) }
            let line = content.bubble ?? PerchLines.compose(variant == "long"
                ? PerchFacts(app: "Obsidian", category: .notes, waiting: 2) : PerchFacts(app: "Xcode", category: .ide), seed: 3)
            let m = Self.perchMock(variant, visible: visible, chars: line.count)
            guard let spot = m.spot else { lastTarget = "none"; return nil }
            var c = content
            c.bubble = line
            let g = SceneGeometry(home: home, target: spot.eyes, visible: visible, bubble: spot.bubble)
            guard let (origin, size) = Self.panelFrame(g, screen: screen.frame) else { return nil }
            var run = SceneRun(kind: kind, start: Date(), geometry: g, origin: origin, size: size, clips: SceneArt.clips, content: c,
                               abortedAt: nil, backdropWindow: backdrop ? m.window : nil, rowsCap: rowsCap)
            run.backdropAbove = backdrop ? m.above : []
            lastTarget = "perch(mock) \(spot.edge.rawValue)"
            pickTransitions(&run)
            return run
        case .vibe:
            // На окне плеера (или переднем окне); места нет — сцены нет (кивание в notch), в угол не идём.
            if let spot = Self.vibeSpot(on: screen) {
                target = spot.eyes; backdropWindow = spot.window; lastTarget = spot.player ? "player" : "window"
            } else if backdrop || variant == "mock" {
                // Лист или отладка (`scene vibe mock`): муляж окна плеера посреди экрана.
                let w = CGRect(x: visible.midX - 300, y: visible.midY - 220, width: 640, height: 400)
                target = SceneLayout.onWindow(w, visible: visible) ?? corner; backdropWindow = w; lastTarget = "player(mock)"
            } else {
                lastTarget = "none"
                return nil
            }
        }
        let g = SceneGeometry(home: home, target: target, area: area, visible: visible, cursor: NSEvent.mouseLocation)
        guard let (origin, size) = Self.panelFrame(g, screen: screen.frame) else { return nil }
        var run = SceneRun(kind: kind, start: Date(), geometry: g, origin: origin, size: size, clips: SceneArt.clips, content: content,
                           abortedAt: nil, backdropWindow: backdrop ? backdropWindow : nil, rowsCap: rowsCap)
        pickTransitions(&run)
        return run
    }

    /// Виды входа и выхода по зерну, не повторяя прошлые; Reduce Motion — только полосы, без вспышек.
    private func pickTransitions(_ run: inout SceneRun) {
        fxCount += 1
        let seed = (Int(Date().timeIntervalSince1970 * 1000) & 0xFFFFF) &+ fxCount &* 7919
        let rm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        run.seed = seed
        run.reduceMotion = rm
        run.enter = Transitions.pick(.enter, seed: seed, avoid: lastEnter, reduceMotion: rm)
        run.exit = Transitions.pick(.exit, seed: seed, avoid: lastExit, reduceMotion: rm)
        lastEnter = run.enter
        lastExit = run.exit
    }

    /// Муляж «смотрит в терминал» для листа: окно терминала посреди экрана, реплики по ходу. Варианты: `watch` —
    /// смотрит, на 6-й секунде новая реплика; `watchgloat` — сессия доработала на 5-й (злорадство и уход);
    /// `watchend` — сессию закрыли на 4-й.
    private func watchMock(_ variant: String?, home: CGRect, visible: CGRect, screen: CGRect, content: SceneContent) -> SceneRun? {
        let w = CGRect(x: visible.midX - 330, y: visible.midY - 230, width: 660, height: 420)
        let first = SessionRemark.opening(WatchedSession(name: "votek2", status: .running, since: 0,
                                                         tail: ["Running tests…", "npm test"]), now: 240)
        // Пузырь — под самую длинную реплику листа (живой показ подгоняет его под каждую, `watchSay`).
        let longest = max(first.count, variant == "watchgloat" ? 29 : 10)
        guard let spot = PerchLayout.spot(window: w, above: [], visible: visible, bubble: PerchLayout.bubbleSize(chars: longest))
        else { return nil }
        var c = content
        c.bubble = first
        c.says = [first]
        let g = SceneGeometry(home: home, target: spot.eyes, area: w, visible: visible, bubble: spot.bubble)
        guard let (origin, size) = Self.panelFrame(g, screen: screen) else { return nil }
        var run = SceneRun(kind: .perch, start: Date(), geometry: g, origin: origin, size: size, clips: SceneArt.clips, content: c,
                           abortedAt: nil, backdropWindow: w, rowsCap: 1)
        var watch = SceneWatch(window: w, says: [SceneSay(at: WatchTimeline.firstSay, chars: first.count)])
        switch variant {
        case "watchgloat":
            let line = "Готово. Без тебя справился ^^"
            watch.says.append(SceneSay(at: 5.0, chars: line.count))
            watch.gloatAt = 5.0
            c.bubble = line
            c.says.append(line)
        case "watchend":
            watch.end = 4.0
        case "watchghost":
            // Связь с хостом потеряна на 4-й секунде: пиксельный призрак.
            watch.ghostAt = 4.0
        case "watchsleep":
            // Никто не трогает: на 41-й секунде засыпает, на 50-й реплика будит.
            let line = "Ещё пыхтит."
            watch.says.append(SceneSay(at: 50.0, chars: line.count))
            c.bubble = line
            c.says.append(line)
        default:
            let line = "Упало! Ха."
            watch.says.append(SceneSay(at: 6.0, chars: line.count))
            c.bubble = line
            c.says.append(line)
        }
        run.content = c
        run.watch = watch
        pickTransitions(&run)
        run.enter = .columnSmear
        lastTarget = "watch(mock) \(spot.edge.rawValue)"
        return run
    }

    /// Муляж для листа/отладки «на окне»: окно посреди экрана; `left` — правый верх закрыт другим окном, `side` — окно
    /// упирается в строку меню (висит на боку), `bottom` — и справа места нет (нижний край).
    static func perchMock(_ variant: String?, visible v: CGRect, chars: Int) -> (window: CGRect, above: [CGRect], spot: PerchSpot?) {
        var w = CGRect(x: v.midX - 320, y: v.midY - 220, width: 640, height: 400)
        var above: [CGRect] = []
        switch variant?.replacingOccurrences(of: "mock", with: "") {
        case "left": above = [CGRect(x: w.maxX - 220, y: w.maxY - 120, width: 420, height: 300)]
        case "side": w = CGRect(x: v.midX - 420, y: v.midY - 140, width: 640, height: v.maxY - (v.midY - 140))
        case "bottom": w = CGRect(x: v.maxX - 700, y: v.midY - 60, width: 700, height: v.maxY - (v.midY - 60))
        default: break
        }
        return (w, above, PerchLayout.spot(window: w, above: above, visible: v, bubble: PerchLayout.bubbleSize(chars: chars)))
    }

    /// Где кивать под музыку на экране notch (окно плеера, иначе переднее окно); nil — места нет.
    static func vibeSpot(on screen: NSScreen) -> (eyes: CGRect, window: CGRect, player: Bool)? {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let primary = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let players = Set(NSWorkspace.shared.runningApplications
            .filter { SceneLayout.players.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        return SceneLayout.vibeSpot(windows: raw.compactMap(WindowInfo.from), players: players,
                                    front: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                    own: ProcessInfo.processInfo.processIdentifier, screen: screen.frame,
                                    visible: screen.visibleFrame, primaryHeight: primary)
    }

    /// Панель — всё, что сцена может занять, в пределах экрана; в спокойной фазе глаз на столе (`compact`) — только
    /// вокруг них.
    static func panelFrame(_ g: SceneGeometry, screen: CGRect, compact: CGRect? = nil) -> (CGPoint, CGSize)? {
        let bounds = (compact ?? g.bounds).intersection(screen).integral
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
        guard !offscreenOnly else { log?("scene \(kind.rawValue): skip offscreen-only (scene live on)"); return false }
        stop()
        guard let run = makeRun(kind, variant: variant, terminal: terminal, content: content, around: around) else {
            log?("scene \(kind.rawValue): \(kind == .vibe && lastTarget == "none" ? "no place" : "no screen")"); return false
        }
        show(run)
        log?("scene \(kind.rawValue) → \(lastTarget) fx=\(run.enter.rawValue)/\(run.exit.rawValue) frame=\(NSStringFromRect(panel?.frame ?? .zero))")
        return true
    }

    /// «На окне»: куда сесть (место уже выбрано `PerchCenter`), экран окна, реплика.
    struct PerchShow {
        var spot: PerchSpot
        var window: CGRect
        var screen: CGRect
        var visible: CGRect
        var line: String
    }

    /// Сесть на окно. Экран не тот, где notch, — молния приходит с верхнего края того экрана (панель одного экрана).
    @discardableResult
    func perch(_ p: PerchShow) -> Bool {
        guard !suppressed else { log?("scene perch: skip fullscreen"); return false }
        guard !offscreenOnly else { log?("scene perch: skip offscreen-only (scene live on)"); return false }
        stop()
        let notchScreen = screen()?.frame
        var home = self.home() ?? CGRect(x: p.screen.midX - 16, y: p.screen.maxY - 20, width: 32, height: 16)
        if notchScreen != p.screen { home = CGRect(x: p.screen.midX - 16, y: p.screen.maxY - 18, width: 32, height: 16) }
        var c = content()
        c.bubble = p.line
        let g = SceneGeometry(home: home, target: p.spot.eyes, visible: p.visible, cursor: NSEvent.mouseLocation, bubble: p.spot.bubble)
        guard let (origin, size) = Self.panelFrame(g, screen: p.screen) else { return false }
        var run = SceneRun(kind: .perch, start: Date(), geometry: g, origin: origin, size: size, clips: SceneArt.clips, content: c,
                           abortedAt: nil, backdropWindow: nil, rowsCap: 1)
        run.screenFrame = p.screen
        pickTransitions(&run)
        lastTarget = "perch \(p.spot.edge.rawValue)\(notchScreen == p.screen ? "" : " (другой экран)")"
        show(run)
        log?("scene perch → \(lastTarget) fx=\(run.enter.rawValue)/\(run.exit.rawValue) frame=\(NSStringFromRect(panel?.frame ?? .zero))")
        return true
    }

    /// Окно сдвинули — мини-прыжок на новое место (0,2 с), панель на это время — оба места.
    func perchHop(to spot: PerchSpot) {
        guard var run = model.run, run.kind == .perch, run.abortedAt == nil, let t = elapsed,
              let screen = run.screenFrame ?? screen()?.frame else { return }
        let w = run.wall()
        let before = SceneLayout.compactPanel(.perch, geometry: run.geometry)
        run.hopFrom = run.geometry.target
        run.hopAt = t
        run.perchHold = false
        if run.clock.pinned { run.clock.pin(false, wall: w, calm: true) }
        run.geometry.target = spot.eyes
        run.geometry.bubble = spot.bubble
        let after = SceneLayout.compactPanel(.perch, geometry: run.geometry)
        if let a = before, let b = after, let (origin, size) = Self.panelFrame(run.geometry, screen: screen, compact: a.union(b)) {
            run.origin = origin
            run.size = size
            panel?.setFrame(CGRect(origin: origin, size: size), display: true)
        }
        model.run = run
        log?("scene perch: hop → \(Int(spot.eyes.minX)),\(Int(spot.eyes.minY))")
        reschedule()
        DispatchQueue.main.asyncAfter(deadline: .now() + PerchTimeline.hopLen + 0.05) { [weak self] in
            guard self?.model.run?.kind == .perch else { return }
            self?.scheduleCompact()
        }
    }

    /// Окно тащат — держится на месте (таймлайн стоит, глитч 1); отпустили — `perchHop` или `perchHold(false)`.
    func perchHold(_ on: Bool) {
        guard var run = model.run, run.kind == .perch, run.abortedAt == nil, run.perchHold != on else { return }
        let w = run.wall()
        run.perchHold = on
        // Тот же механизм, что «📌» (наведение мышью его не снимает): уйти посреди перетаскивания она не должна.
        run.clock.pin(on, wall: w, calm: run.calm(wall: w))
        model.run = run
        reschedule()
    }

    /// «Смотрит в терминал»: куда сесть (место выбрано `PerchCenter`), окно терминала, первая реплика.
    struct WatchShow {
        var spot: PerchSpot
        var window: CGRect
        var screen: CGRect
        var visible: CGRect
        var line: String
    }

    /// Вылезти из терминала: молния в окно → окно краснеет и стекает → натекает на край окна → смотрит (≤ 60 с).
    @discardableResult
    func watch(_ p: WatchShow) -> Bool {
        guard !suppressed else { log?("scene watch: skip fullscreen"); return false }
        guard !offscreenOnly else { log?("scene watch: skip offscreen-only (scene live on)"); return false }
        stop()
        let notchScreen = screen()?.frame
        var home = self.home() ?? CGRect(x: p.screen.midX - 16, y: p.screen.maxY - 20, width: 32, height: 16)
        if notchScreen != p.screen { home = CGRect(x: p.screen.midX - 16, y: p.screen.maxY - 18, width: 32, height: 16) }
        var c = content()
        c.bubble = p.line
        c.says = [p.line]
        // `area` — окно терминала: панель на входе накрывает его целиком (размаз), в покое — только глаза и пузырь.
        let g = SceneGeometry(home: home, target: p.spot.eyes, area: p.window, visible: p.visible, cursor: NSEvent.mouseLocation,
                              bubble: p.spot.bubble)
        guard let (origin, size) = Self.panelFrame(g, screen: p.screen) else { return false }
        var run = SceneRun(kind: .perch, start: Date(), geometry: g, origin: origin, size: size, clips: SceneArt.clips, content: c,
                           abortedAt: nil, backdropWindow: nil, rowsCap: 1)
        run.screenFrame = p.screen
        run.watch = SceneWatch(window: p.window, says: [SceneSay(at: WatchTimeline.firstSay, chars: p.line.count)])
        pickTransitions(&run)
        // Вылезает из размаза — столбцами.
        run.enter = run.reduceMotion ? .glitchBars : .columnSmear
        lastTarget = "watch \(p.spot.edge.rawValue)\(notchScreen == p.screen ? "" : " (другой экран)")"
        show(run)
        log?("scene watch → \(lastTarget) frame=\(NSStringFromRect(panel?.frame ?? .zero))")
        return true
    }

    /// Смотрит в терминал прямо сейчас (в покое, не уходит).
    var watching: Bool {
        guard let run = model.run, run.watch != nil, run.abortedAt == nil, let t = elapsed else { return false }
        return t < WatchTimeline.leaveStart(run.watch!)
    }

    /// Новая реплика в терминале: печатается с ближайшего момента покоя; `bubble` — пузырь под её длину.
    /// `gloat` — злорадствует с этого момента и уходит; `leave` — уходит, дочитав.
    func watchSay(_ line: String, bubble: CGRect?, gloat: Bool = false, leave: Bool = false) {
        guard var run = model.run, var w = run.watch, run.abortedAt == nil, let t = elapsed,
              t < WatchTimeline.leaveStart(w) else { return }
        let at = max(t, WatchTimeline.firstSay)
        w.says.append(SceneSay(at: at, chars: line.count))
        if gloat { w.gloatAt = at }
        // Уходит, дочитав реплику.
        if leave { w.end = min(w.end, at + Double(line.count) / PerchTimeline.cps + 1.6) }
        run.watch = w
        run.content.bubble = line
        run.content.says.append(line)
        if let bubble { run.geometry.bubble = bubble }
        model.run = run
        log?("scene watch: say\(gloat ? " (злорадство)" : "") at \(String(format: "%.1f", at))")
        reschedule()
        scheduleCompact()
        refreshIgnores()
    }

    /// Связь с хостом сессии потеряна: рассыпается пиксельным призраком на краю окна и уходит.
    func watchGhost() {
        guard var run = model.run, var w = run.watch, run.abortedAt == nil, w.ghostAt == nil, let t = elapsed,
              t < WatchTimeline.leaveStart(w) else { return }
        w.ghostAt = max(WatchTimeline.arrive, t)
        if let g = w.gloatAt, g > w.ghostAt! { w.gloatAt = nil }
        run.watch = w
        model.run = run
        log?("scene watch: призрак (связь потеряна) at \(String(format: "%.1f", t))")
        reschedule()
        scheduleCompact()
    }

    /// Перестать смотреть сейчас (сессия пропала, досмотрела раньше): уход с края окна.
    func watchEnd(_ why: String) {
        guard var run = model.run, var w = run.watch, run.abortedAt == nil, let t = elapsed,
              t < WatchTimeline.leaveStart(w) else { return }
        w.end = max(WatchTimeline.arrive, t)
        if let g = w.gloatAt, g > w.end { w.gloatAt = nil }
        run.watch = w
        model.run = run
        log?("scene watch: end (\(why)) at \(String(format: "%.1f", t))")
        reschedule()
        scheduleCompact()
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
        compactWork?.cancel()
        compactWork = nil
        setIgnores(true)
        model.run = run
        panel.orderFrontRegardless()
        onRunning?(true)
        reschedule()
        scheduleCompact()
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

    /// Панель под текущую фазу: в спокойной фазе глаз на столе — сжатая вокруг них, иначе — от notch до цели.
    private func fitPanel() {
        guard var run = model.run, let screen = run.screenFrame ?? screen()?.frame else { return }
        let w = run.wall()
        let compact = run.abortedAt == nil && SceneTimeline.calm(run.kind, run.options)?.contains(run.clock.time(w)) == true
            ? SceneLayout.compactPanel(run.kind, geometry: run.geometry) : nil
        guard let (origin, size) = Self.panelFrame(run.geometry, screen: screen, compact: compact),
              origin != run.origin || size != run.size else { return }
        run.origin = origin
        run.size = size
        model.run = run
        panel?.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// Следующая граница спокойной фазы (по часам сцены) — там панель сжимается/разжимается. Удержание двигает её:
    /// проверяем ещё раз, когда сработает.
    private func scheduleCompact() {
        compactWork?.cancel()
        compactWork = nil
        fitPanel()
        guard let run = model.run, run.abortedAt == nil, SceneLayout.compactPanel(run.kind, geometry: run.geometry) != nil,
              let calm = SceneTimeline.calm(run.kind, run.options) else { return }
        let t = run.clock.time(run.wall())
        let next = t < calm.lowerBound ? calm.lowerBound : t < calm.upperBound ? calm.upperBound - 1.0 / 24 : nil
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in self?.scheduleCompact() }
        compactWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, next - t), execute: work)
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
            if finish { self?.finish() } else { self?.reschedule() }
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

    static func isRow(_ k: SceneHotspot.Kind?) -> Bool {
        if case .row? = k { return true }
        return false
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
        if !run.kind.boxed, run.kind != .perch, run.content.track != nil {
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
        // Наезд в глаз и 12 fps на секунду — только когда курсор входит в строку сессий или уходит с неё.
        if over?.kind != run.hover, Self.isRow(over?.kind) || Self.isRow(run.hover) { run.hoverAt = w }
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
        guard dragging, var run = model.run, run.abortedAt == nil, let screen = run.screenFrame ?? screen()?.frame else { return }
        let before = run.geometry.area ?? run.geometry.target
        run.geometry = run.geometry.moved(by: d)
        let after = run.geometry.area ?? run.geometry.target
        run.offset.dx += after.minX - before.minX
        run.offset.dy += after.minY - before.minY
        let compact = run.calm(wall: run.wall()) ? SceneLayout.compactPanel(run.kind, geometry: run.geometry) : nil
        guard let (origin, size) = Self.panelFrame(run.geometry, screen: screen, compact: compact) else { return }
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
    func abort(_ why: String, overload: Bool = false) {
        guard var run = model.run, run.abortedAt == nil else { return }
        let w = run.wall()
        run.clock.release(w)
        let t = run.clock.time(w)
        guard t < SceneTimeline.duration(run.kind, run.options) - SceneTimeline.recallDuration else { return }
        run.abortedAt = t
        run.overload = overload && run.kind == .perch
        run.hover = nil
        dragging = false
        model.run = run
        setIgnores(true)
        removeMonitors()
        log?("scene abort (\(why)\(run.overload ? ", перегрузка" : "")) at \(String(format: "%.2f", t))")
        reschedule()
        // Молния домой — нужна вся панель от глаз до notch.
        scheduleCompact()
    }

    /// Конец по часам: доиграла сама (без обрыва) — `onFinished`.
    private func finish() {
        let done = model.run.flatMap { $0.abortedAt == nil ? $0.kind : nil }
        stop()
        if let done { onFinished?(done) }
    }

    /// Вайб: сменился трек — глитч 1 на месте, конец сцены не сдвигается.
    func markTrackChange() {
        guard var run = model.run, run.kind == .vibe, run.abortedAt == nil, let t = elapsed else { return }
        run.glitchMarks.append(t)
        model.run = run
        log?("scene vibe: track changed at \(String(format: "%.1f", t))")
    }

    /// Сразу убрать панель.
    func stop() {
        endWork?.cancel(); endWork = nil
        compactWork?.cancel(); compactWork = nil
        removeMonitors()
        dragging = false
        let was = model.run?.kind
        model.run = nil
        setIgnores(true)
        panel?.orderOut(nil)
        if let was { onRunning?(false); log?("scene end"); onEnded?(was) }
    }

    /// Полноэкранное приложение: сцены не играют, идущая гаснет сразу.
    func setSuppressed(_ value: Bool) {
        suppressed = value
        if value { stop() }
    }

    /// Кадров сцены нарисовано (для `dump`: проверка «кадр по событию»).
    private(set) static var frames = 0
    static func countFrame() { frames += 1 }

    var status: [String: Any] {
        var out: [String: Any] = ["running": running, "suppressed": suppressed, "offscreenOnly": offscreenOnly, "tracking": !monitors.isEmpty, "frames": Self.frames]
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
            out["fx"] = "\(run.enter.rawValue)/\(run.exit.rawValue)\(run.reduceMotion ? " reduceMotion" : "")"
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
        if kind == .sessions, variant == "hover" {
            // Курсор на строке 2-й с 3 с до 5 с (наезд в глаз); лист — по таймлайну, удержания нет.
            run.hover = .row(min(1, max(0, run.rowsCap - 1)))
            run.hoverAt = 3.0
        }
        if kind == .sessions, variant == "busy" { run.content.waiting = 3 }
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
        // Переходы на листе: `bars|smear|burst` — виды входа/выхода; `reduce` — как с Reduce Motion; `track` — смена трека.
        switch variant {
        case "bars": run.enter = .glitchBars; run.exit = .glitchBars
        case "smear": run.enter = .columnSmear; run.exit = .columnSmear
        case "burst": run.enter = .burstIn; run.exit = .ribbonOut
        case "reduce": run.enter = .glitchBars; run.exit = .glitchBars; run.reduceMotion = true
        case "track": run.glitchMarks = [1.3]
        default: break
        }
        if kind == .perch {
            // `hop` — окно сдвинули на 4-й секунде; `hold` — окно тащат; `shoo` — прогнали кликом на 5-й секунде.
            if variant == "hop" { run.hopAt = 4.0; run.hopFrom = run.geometry.target.offsetBy(dx: -170, dy: -60) }
            if variant == "hold" { run.perchHold = true }
            if variant == "shoo" { run.abortedAt = 5.0 }
            // `overload` — прогнали тем, что ждут сразу несколько сессий: рой глаз, потом молния домой.
            if variant == "overload" { run.abortedAt = 5.0; run.overload = true }
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
        times += run.watch != nil ? Self.watchTimes(run.watch!) : Self.keyTimes(kind)
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
        if let b = run.geometry.bubble { focus = focus.union(b.insetBy(dx: -20, dy: -20)) }
        if let h = run.hopFrom { focus = focus.union(h.insetBy(dx: -40, dy: -40)) }
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

    /// Кадры листа «смотрит в терминал»: молния, размаз, вылезает, печать реплик, злорадство, уход.
    static func watchTimes(_ w: SceneWatch) -> [Double] {
        let leave = WatchTimeline.leaveStart(w)
        var out = [0.3, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95, 1.1, 1.25, 1.4, 1.7, 2.2, 2.8]
        out += w.says.dropFirst().flatMap { [$0.at - 0.05, $0.at + 0.4, $0.at + 1.4] }
        if let g = w.gloatAt { out += [g + 0.2, g + 0.9, g + 1.6] }
        if let g = w.ghostAt { out += [g + 0.1, g + 0.4, g + 0.8, g + 1.2] }
        for (a, _) in RigMoments.sleepWindows(w) { out += [a + 0.5, a + 1.5, a + 3.2, a + 5] }
        out += [leave + 0.15, leave + 0.35, leave + 0.6]
        return out
    }

    static func keyTimes(_ kind: SceneKind) -> [Double] {
        switch kind {
        case .teleport: [0.05, 0.15, 0.25, 0.35, 0.42, 0.46, 0.55, 0.62, 0.7, 0.8, 0.9, 4.45, 4.52, 4.6, 4.66, 4.78, 4.9]
        case .window: [0.3, 0.45, 0.7, 0.85, 0.95, 1.5, 2.5, 7.1, 7.3, 7.5, 7.7]
        case .takeover: [0.6, 0.9, 1.3, 1.9, 2.3, 2.8, 3.4, 3.9, 4.1, 4.4]
        case .vibe: [0.1, 0.3, 0.33, 0.45, 0.52, 0.6, 0.68, 1.0, 1.32, 1.4, 30.0, 57.9, 58.1, 58.25, 58.4, 58.6, 58.75, 58.9,
                     59.05, 59.25, 59.35, 59.5, 59.7]
        case .sessions: [0.3, 0.7, 0.9, 1.2, 1.5, 2.2, 3.0, 3.1, 3.3, 3.6, 4.4, 7.3, 7.5, 7.7]
        case .thinking: [0.7, 0.9, 1.2, 1.5, 2.6, 3.4, 4.3, 5.1]
        case .answer: [0.7, 0.9, 1.2, 2.0, 4.2, 4.6, 5.0, 5.6, 6.0]
        case .reply: [0.15, 0.4, 0.7, 1.0, 1.2, 1.7, 2.2, 2.6, 2.9, 3.2, 3.5, 3.8]
        case .music: [0.7, 0.9, 1.2, 2.6, 2.8, 3.1, 3.55, 3.7, 4.6, 4.8, 5.4, 5.6, 6.2]
        case .perch: [0.1, 0.2, 0.3, 0.35, 0.45, 0.6, 0.75, 0.92, 0.97, 1.1, 1.3, 1.5, 1.8, 2.4, 3.2, 4.06, 4.12, 4.16, 4.2, 5.0, 5.1,
                      5.3, 5.5, 6.5, 7.5, 8.2]
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
