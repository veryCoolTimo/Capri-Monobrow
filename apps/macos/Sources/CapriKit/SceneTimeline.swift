import Foundation
import CoreGraphics

/// Имена клипов сериала (`~/.capri/art/eyes/clips.json`) — одни на сцены, `ShowArt` и встроенный арт `CapriArt`,
/// чтобы опечатка не превращалась молча в `look`.
public enum SceneClip {
    public static let look = "look"
    public static let close = "close"
    public static let many = "many"
    public static let slits = "slits"
    public static let appear = "appear"
    public static let talk = "talk"
    public static let shut = "shut"
    public static let burst = "burst"
    public static let crazy = "crazy"
    public static let teleOut = "tele_out"
    public static let teleIn = "tele_in"
    public static let melt = "melt"
    public static let texMosh = "tex_mosh"
    public static let texGraffiti = "tex_graffiti"
    // Проход 3: крупная Capri в окнах (16:10, рисуются aspect-fill по лицу окна).
    /// Маска целиком: глаза + рот хлопает.
    public static let faceTalk = "face_talk"
    /// Кивок, глаза большие, довольные закрытые глаза ^^ (1,5–2,5 с), снова открыла.
    public static let faceNod = "face_nod"
    /// Крупно два глаза, камера ведёт вбок (играть туда-обратно).
    public static let faceScan = "face_scan"
    /// Оскал, глитч, зажмурилась, взрыв глаз (с 2,17 с).
    public static let faceGrin = "face_grin"
    /// По плечи в розовых волосах, петля.
    public static let hairBob = "hair_bob"
    /// Голова набок, взгляд в сторону, прищур.
    public static let sideLook = "side_look"
    /// Наезд в один глаз до огромного зрачка.
    public static let eyeZoom = "eye_zoom"
    /// Все известные клипы (что `ShowArt` читает из `clips.json`).
    public static let all = [look, close, many, slits, appear, talk, shut, burst, crazy, teleOut, teleIn, melt, texMosh, texGraffiti,
                             faceTalk, faceNod, faceScan, faceGrin, hairBob, sideLook, eyeZoom]
}

/// Сцены персонажа на рабочем столе: короткие представления, после которых глаза снова только в notch. Фоновые —
/// ≤ 8 с; окна по действию человека (`thinking`, `answer`) — дольше, а наведение, перетаскивание и «📌» держат
/// сцену на месте (`SceneClock`).
/// Всё здесь — чистые функции времени: живой показ и снимки (`scene sheet`) дают одинаковые кадры.
/// Координаты — глобальные AppKit (начало внизу слева).
public enum SceneKind: String, CaseIterable, Codable {
    /// Телепорт из notch в угол или на верхний край окна, посмотрела вокруг, обратно.
    case teleport
    /// «Переделывается в окно»: розовая рамка `CAPRI//SYS`, внутри глаза и строка статуса.
    case window
    /// «Управляет компом» — только рисунок: волна, нарисованный курсор, сама печатает, граффити.
    case takeover
    /// «Видит, что играет трек»: телепорт в угол, кивает под музыку, ноты.
    case vibe
    /// Окно `CAPRI//SESSIONS`: до 4 строк сессий, клик по строке — сессия в основном окне.
    case sessions
    /// Окно `CAPRI//THINK`: помощник думает над вопросом, notch свёрнут. Клик — помощник в notch.
    case thinking
    /// Окно `CAPRI//ANSWER`: ответ помощника, кнопки предложения.
    case answer
    /// Человек ответил сессии через Capri: телепорт к окну терминала, «→ имя ✓».
    case reply
    /// Окно `CAPRI//MUSIC`: «включи …» или кнопки музыки — ищет, включает, ⏮ ⏯ ⏭.
    case music

    public var title: String {
        switch self {
        case .teleport: "Телепорт"
        case .window: "Окно"
        case .takeover: "Захват"
        case .vibe: "Вайб"
        case .sessions: "Сессии"
        case .thinking: "Думает"
        case .answer: "Ответ"
        case .reply: "К терминалу"
        case .music: "Музыка"
        }
    }

    /// Сцены-окна с рамкой `CAPRI//…`, «×» и «📌».
    public var boxed: Bool { [.window, .sessions, .thinking, .answer, .music].contains(self) }

    /// Сцена держится на месте при наведении/перетаскивании (`SceneClock`); захват — нет (он весь подвижный).
    public var holdable: Bool { self != .takeover }
}

/// Параметры сцены из живых данных (длины строк, число строк окна, моменты событий) — всё, что влияет на кадр.
public struct SceneOptions: Equatable {
    /// Длина строки статуса окна (`window`).
    public var text = 0
    /// Длины строк «захвата».
    public var lines: [Int] = []
    /// Строк в окне сессий (показывается до 4).
    public var rows = 0
    /// Сколько сессий ждут: ≥ 3 — `crazy` в окне сессий.
    public var waiting = 0
    /// Ответ помощника: строк после переноса (до 6) и букв всего.
    public var answerLines = 0
    public var answerChars = 0
    /// В ответе есть неподтверждённое действие (кнопки «отправить»/«отмена») — читать дольше.
    public var proposal = false
    /// Ответ продолжает окно «думает» (то же окно, глитч-переход вместо прилёта).
    public var continued = false
    /// Время таймлайна, когда предложение отправили (`burst` один раз).
    public var burstAt: Double?
    /// Длина подписи «→ имя ✓» сцены `reply`.
    public var caption = 0
    /// Время таймлайна, когда ответ сессии не дошёл (`reply`: `crazy` + глитч 3).
    public var failedAt: Double?
    /// Окно музыки: смены состояния (ищет → играет → пауза …) по времени таймлайна.
    public var musicMarks: [SceneMusicMark] = []
    /// Музыка известна (есть что переключать) и кнопки ⏮ ⏯ ⏭ под глазами сейчас показаны (наведение на глаза).
    public var musicKnown = false
    public var controls = false
    /// Насколько таймлайн отстал от стены (удержание): клипы окна музыки идут по стене, состояние — по таймлайну.
    public var lag = 0.0
    /// Окно сессий: строка под курсором и стена, когда наведение сменилось (наезд в глаз / глитч возврата).
    public var hoverRow: Int?
    public var hoverAt = 0.0

    public init(text: Int = 0, lines: [Int] = [], rows: Int = 0, waiting: Int = 0, answerLines: Int = 0, answerChars: Int = 0,
                proposal: Bool = false, continued: Bool = false, burstAt: Double? = nil, caption: Int = 0, failedAt: Double? = nil) {
        self.text = text; self.lines = lines; self.rows = rows; self.waiting = waiting; self.answerLines = answerLines
        self.answerChars = answerChars; self.proposal = proposal; self.continued = continued; self.burstAt = burstAt
        self.caption = caption; self.failedAt = failedAt
    }
}

/// Где играет сцена.
public struct SceneGeometry: Equatable {
    /// Глаза в notch (откуда уходит и куда возвращается).
    public var home: CGRect
    /// Глаза в цели.
    public var target: CGRect
    /// Рамка «окна» (сцена окна) или область захвата; для телепорта и вайба — nil.
    public var area: CGRect?
    /// `visibleFrame` экрана notch: всё рисуется внутри.
    public var visible: CGRect
    /// Курсор — куда глаза «смотрят» (только наклон).
    public var cursor: CGPoint?

    public init(home: CGRect, target: CGRect, area: CGRect? = nil, visible: CGRect, cursor: CGPoint? = nil) {
        self.home = home; self.target = target; self.area = area; self.visible = visible; self.cursor = cursor
    }

    /// Всё, что сцена может занять, с запасом под молнию и вспышку.
    public var bounds: CGRect {
        var r = home.union(target)
        if let area { r = r.union(area) }
        return r.insetBy(dx: -90, dy: -90)
    }

    /// Перетаскивание: цель и окно сдвигаются вместе, не выходя за `visible`; `home` (notch) на месте.
    public func moved(by d: CGVector) -> SceneGeometry {
        let zone = area ?? target
        let to = SceneLayout.clamp(zone.offsetBy(dx: d.dx, dy: d.dy), to: visible)
        let dx = to.minX - zone.minX, dy = to.minY - zone.minY
        var g = self
        g.target = target.offsetBy(dx: dx, dy: dy)
        g.area = area?.offsetBy(dx: dx, dy: dy)
        return g
    }
}

/// Молния между двумя точками (глобальные координаты).
public struct SceneBolt: Equatable {
    public var from: CGPoint
    public var to: CGPoint
    /// Форма: меняется раз в два тика 24 fps («кипит»).
    public var seed: Int
    /// 0…1: доля пути, которую молния уже прошла.
    public var reach: CGFloat
}

/// Рамка «окна» Capri.
public struct SceneWindow: Equatable {
    /// Текущая рамка (растёт из линии).
    public var rect: CGRect
    /// 0…1: раскрытие (0.5 — линия во всю ширину, 1 — окно).
    public var open: CGFloat
    /// Видна строка заголовка и «×».
    public var chrome: Bool
    /// 0…1: рассыпается в частицы.
    public var melt: CGFloat
    /// Сколько букв строки статуса (ответа) напечатано; в окне сессий — сколько строк показано; в «думает» — точек.
    public var typed: Int
    /// Курсор печати мигает.
    public var caret: Bool
    /// «Думает»: сканлайн-вайп сверху вниз, 0…1 (nil — нет).
    public var scan: CGFloat?

    public init(rect: CGRect, open: CGFloat, chrome: Bool, melt: CGFloat, typed: Int, caret: Bool, scan: CGFloat? = nil) {
        self.rect = rect; self.open = open; self.chrome = chrome; self.melt = melt; self.typed = typed; self.caret = caret
        self.scan = scan
    }
}

/// Подпись сцены `reply` рядом с глазами («→ votek2 ✓»): правый край — `anchor`.
public struct SceneCaption: Equatable {
    public var anchor: CGPoint
    /// Сколько букв напечатано.
    public var typed: Int
    /// Не дошло — красным.
    public var failed: Bool
}

/// «Захват» области.
public struct SceneTakeover: Equatable {
    public var area: CGRect
    /// 0…1: розовая волна сверху вниз.
    public var wave: CGFloat
    /// Нарисованный курсор (nil — нет).
    public var cursor: CGPoint?
    /// Кольца «кликов»: центр и 0…1 (расходятся и гаснут).
    public var rings: [SceneRing]
    /// Сколько букв каждой строки напечатано.
    public var typed: [Int]
    /// 0…1: пятна граффити.
    public var graffiti: CGFloat
    /// Красная молния по краю (зерно) — на 2–4 кадра.
    public var edgeBolt: Int?
    /// 1 — во всю высоту, 0 — сжато в линию (финал).
    public var collapse: CGFloat
}

public struct SceneRing: Equatable {
    public var center: CGPoint
    public var progress: CGFloat
}

/// Нота над глазами в вайбе.
public struct SceneNote: Equatable {
    public var center: CGPoint
    public var alpha: CGFloat
    public var glyph: Int
}

/// Крупная Capri в окне: клип рисуется aspect-fill с обрезкой по прямоугольнику глаз, поверх — процедурное
/// движение (детерминировано по времени): сдвиг (доли размера; `dy` > 0 — вверх), масштаб, наклон (градусы),
/// вспышка яркости 0…1.
public struct SceneFace: Equatable {
    public var shift: CGVector
    public var zoom: CGFloat
    public var tilt: Double
    public var pulse: CGFloat
    /// Отразить по горизонтали (тот же клип в другом окне выглядит иначе).
    public var mirror: Bool

    public init(shift: CGVector = .zero, zoom: CGFloat = 1, tilt: Double = 0, pulse: CGFloat = 0, mirror: Bool = false) {
        self.shift = shift; self.zoom = zoom; self.tilt = tilt; self.pulse = pulse; self.mirror = mirror
    }
}

/// Кадр сцены в момент `t`.
public struct SceneFrame: Equatable {
    /// Фаза — для тестов и `dump`.
    public var phase: String
    /// Глаза (nil — нет на столе).
    public var eyes: CGRect?
    /// Клип сериала, секунды от его начала, по кругу или с остановкой на последнем.
    public var clip: String = SceneClip.look
    public var clipT: Double = 0
    /// Как играть клип: один раз (стоп на последнем), по кругу, туда-обратно.
    public var clipMode: FrameClip.Mode = .loop
    /// 1 — обычные глаза, → 0 — сплющены в линию.
    public var squash: CGFloat = 1
    /// Уровень глитча глаз (0 — нет).
    public var glitch = 0
    public var bolt: SceneBolt?
    /// Белая вспышка: центр и сила 0…1.
    public var flash: CGFloat = 0
    public var flashAt: CGPoint?
    public var window: SceneWindow?
    public var takeover: SceneTakeover?
    public var notes: [SceneNote] = []
    /// Кольца-импульсы от глаз (`reply`: «отправила»).
    public var rings: [SceneRing] = []
    public var caption: SceneCaption?
    /// Сцена кончилась — глаза снова в notch.
    public var done = false
    /// Лицо: клип заполняет `eyes` (aspect-fill) с движением; nil — глаза вписаны как раньше. В окнах `eyes` —
    /// прямоугольник лица (`faceRect`), а не полоса глаз 2:1.
    public var face: SceneFace?
    /// `clipT` уже считан по стене (`SceneOptions.lag`) — показ не добавляет отставание удержания.
    public var wallClock = false

    public init(phase: String, eyes: CGRect?, clip: String = SceneClip.look, clipT: Double = 0, loop: Bool = true,
                glitch: Int = 0, done: Bool = false) {
        self.phase = phase; self.eyes = eyes; self.clip = clip; self.clipT = clipT
        self.clipMode = loop ? .loop : .once; self.glitch = glitch; self.done = done
    }

    /// Клип идёт по кругу (или туда-обратно); false — стоп на последнем рисунке.
    public var loop: Bool {
        get { clipMode != .once }
        set { clipMode = newValue ? .loop : .once }
    }

    /// Прямоугольник крупного лица (окна, `reply`); nil — на столе обычные глаза.
    public var faceRect: CGRect? { face != nil ? eyes : nil }

    public static func home(_ phase: String = "home") -> SceneFrame { SceneFrame(phase: phase, eyes: nil, done: true) }
}

public enum SceneTimeline {
    /// Глаза на столе — полоса 2:1.
    public static let eyesSize = CGSize(width: 120, height: 60)
    public static let windowSize = CGSize(width: 300, height: 210)
    /// Лицо у терминала (`reply`), 16:10.
    public static let replySize = CGSize(width: 200, height: 125)
    public static let takeoverSize = CGSize(width: 480, height: 300)
    /// Обрыв (`needsInput`): молния домой.
    public static let recallDuration = 0.35
    /// Темп кивания (ударов в минуту).
    public static let bpm = 112.0
    /// Строки «захвата».
    public static let takeoverLines = 2

    /// «Думает» ждёт ответа помощника не дольше минуты (дальше ответ всё равно покажет notch).
    public static let thinkingDuration = 60.0
    /// Уход окна (свёртывание в линию, молния домой).
    static let foldDuration = 0.9

    public static func duration(_ kind: SceneKind, _ o: SceneOptions = SceneOptions()) -> Double {
        switch kind {
        case .teleport: 5.0
        case .window: 8.0
        case .takeover: 4.6
        case .vibe: 7.0
        case .sessions: 8.0
        case .thinking: thinkingDuration
        case .answer:
            // Прилёт + печать (18 букв/с) + чтение + уход; с кнопками — дольше; потолок 25 с (дальше — «📌»).
            min(25, arrival(kind, o) + Double(o.answerChars) / 18 + (o.proposal ? 10 : max(4, Double(o.answerLines))) + foldDuration)
        case .reply: 4.0
        case .music:
            // Не меньше 8 с и ≥ 5 с после последней смены состояния (ждём плеер не дольше 6 с — потом «не нашла»).
            min(musicCap, max(8, (o.musicMarks.map(\.t).max() ?? 0) + 5))
        }
    }

    /// Потолок окна музыки без «📌».
    public static let musicCap = 40.0

    /// Конец прилёта окна (рамка раскрыта).
    static func arrival(_ kind: SceneKind, _ o: SceneOptions) -> Double { kind == .answer && o.continued ? 0.3 : 1.0 }

    /// Спокойная часть сцены (глаза на месте, молнии нет): показ идёт на 12 fps вместо 24 — панель большая,
    /// каждый кадр перерисовывает её целиком. Захват — весь подвижный. Только здесь есть горячие точки и удержание.
    public static func calm(_ kind: SceneKind, _ o: SceneOptions = SceneOptions()) -> Range<Double>? {
        switch kind {
        case .teleport: 1.0..<4.4
        case .window: 1.0..<7.0
        case .vibe: 0.75..<6.5
        case .takeover: nil
        case .sessions, .thinking, .answer, .music: arrival(kind, o)..<(duration(kind, o) - foldDuration)
        case .reply: 1.5..<3.4
        }
    }

    /// Шаг кадра в момент `t` (после обрыва — всегда 24 fps).
    public static func frameInterval(_ kind: SceneKind, t: Double, aborted: Bool = false, options o: SceneOptions = SceneOptions()) -> Double {
        if !aborted, let c = calm(kind, o), c.contains(t) { return 1.0 / 12 }
        return 1.0 / 24
    }

    /// Кадр сцены `kind` в момент `t`. `clips` — какие клипы сериала есть (без `tele_*` — фолбэк на `close`/`appear`),
    /// `text` — длина строки статуса окна; `lines` — длины строк захвата; `abortedAt` — когда сцену оборвали.
    public static func frame(_ kind: SceneKind, t: Double, geometry g: SceneGeometry, clips: Set<String> = [],
                             text: Int = 0, lines: [Int] = [], abortedAt: Double? = nil) -> SceneFrame {
        frame(kind, t: t, geometry: g, clips: clips, options: SceneOptions(text: text, lines: lines), abortedAt: abortedAt)
    }

    public static func frame(_ kind: SceneKind, t: Double, geometry g: SceneGeometry, clips: Set<String> = [],
                             options o: SceneOptions, abortedAt: Double? = nil) -> SceneFrame {
        if let a = abortedAt, t >= a {
            return recall(kind, t: t, at: a, geometry: g, clips: clips, options: o)
        }
        guard t >= 0, t < duration(kind, o) else { return .home() }
        switch kind {
        case .teleport: return teleport(t, g, clips)
        case .window: return windowForm(t, g, clips, o)
        case .takeover: return takeover(t, g, clips, o.lines)
        case .vibe: return vibe(t, g, clips)
        case .sessions, .thinking, .answer, .music: return boxed(kind, t, g, clips, o)
        case .reply: return reply(t, g, clips, o)
        }
    }

    // MARK: общие куски

    /// Уход: `tele_out` или закрытые глаза, сплющенные в линию 2 px.
    static func out(_ phase: String, at r: CGRect, _ t: Double, len: Double, _ clips: Set<String>) -> SceneFrame {
        let p = CGFloat(min(1, max(0, t / len)))
        var f = SceneFrame(phase: phase, eyes: r, glitch: 3)
        if clips.contains(SceneClip.teleOut) {
            f.clip = SceneClip.teleOut; f.clipT = t * 1.1 / len; f.loop = false
            f.squash = 1 - 0.85 * max(0, p - 0.6) / 0.4
        } else {
            f.clip = SceneClip.close; f.clipT = t; f.loop = false
            f.squash = max(2 / max(r.height, 2), 1 - p)
        }
        return f
    }

    /// Появление: `tele_in` или `appear` с глитчем 4 в начале.
    static func into(_ phase: String, at r: CGRect, _ t: Double, len: Double, _ clips: Set<String>) -> SceneFrame {
        var f = SceneFrame(phase: phase, eyes: r)
        if clips.contains(SceneClip.teleIn) {
            f.clip = SceneClip.teleIn; f.clipT = t * 1.1 / len; f.loop = false
            f.glitch = t < len * 0.3 ? 2 : 0
        } else {
            f.clip = clips.contains(SceneClip.appear) ? SceneClip.appear : SceneClip.look; f.clipT = t; f.loop = false
            f.glitch = t < len * 0.4 ? 4 : t < len * 0.7 ? 2 : 0
            f.squash = min(1, 0.15 + CGFloat(t / (len * 0.4)))
        }
        return f
    }

    /// Перелёт молнией: глаз нет, молния растёт от `a` к `b`, в конце — белая вспышка в `b` на 2 кадра.
    static func jump(_ phase: String, from a: CGRect, to b: CGRect, _ t: Double, len: Double) -> SceneFrame {
        var f = SceneFrame(phase: phase, eyes: nil)
        let p = CGFloat(min(1, max(0, t / (len * 0.6))))
        f.bolt = SceneBolt(from: center(a), to: center(b), seed: Int(t * 12), reach: p)
        let flash = t - len * 0.6
        if flash >= 0 { f.flash = CGFloat(max(0, 1 - flash / (2.0 / 24))); f.flashAt = center(b) }
        return f
    }

    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// Наклон к курсору: ±6 pt по горизонтали.
    static func lean(_ r: CGRect, _ g: SceneGeometry) -> CGRect {
        guard let c = g.cursor else { return r }
        let dx = max(-1, min(1, (c.x - r.midX) / 400)) * 6
        return r.offsetBy(dx: dx, dy: 0)
    }

    /// Редкий глитч 1–2 в покое (24 fps, детерминирован).
    static func idleGlitch(_ t: Double) -> Int {
        let tick = Int(t * 24)
        if TickNoise.burst(tick, period: 40, length: 2, salt: 31) != nil { return TickNoise.unit(tick / 40, 32) < 0.3 ? 2 : 1 }
        return 0
    }

    // MARK: A. Телепорт

    static func teleport(_ t: Double, _ g: SceneGeometry, _ c: Set<String>) -> SceneFrame {
        switch t {
        case ..<0.3: return out("out", at: g.home, t, len: 0.3, c)
        case ..<0.5: return jump("jump", from: g.home, to: g.target, t - 0.3, len: 0.2)
        case ..<1.0: return into("in", at: g.target, t - 0.5, len: 0.5, c)
        case ..<4.4:
            // Смотрит вокруг и моргает (`close`) раз в 2,5 с; без клипа — редкий глитч, как раньше.
            var f = SceneFrame(phase: "look", eyes: lean(g.target, g), clip: SceneClip.look, clipT: t - 1.0)
            let cyc = (t - 1.0).truncatingRemainder(dividingBy: 2.5)
            if c.contains(SceneClip.close) {
                if cyc >= 2.15 { f.clip = SceneClip.close; f.clipT = cyc - 2.15; f.loop = false }
            } else {
                f.glitch = idleGlitch(t)
            }
            return f
        case ..<4.7: return out("leave", at: g.target, t - 4.4, len: 0.3, c)
        case ..<4.85: return jump("back", from: g.target, to: g.home, t - 4.7, len: 0.15)
        default:
            var f = into("home", at: g.home, t - 4.85, len: 0.15, c)
            f.glitch = 2
            return f
        }
    }

    // MARK: B. Окно

    /// «×» окна (глобальные координаты) — единственная кликабельная точка сцены.
    public static func closeRect(_ w: CGRect) -> CGRect {
        CGRect(x: w.maxX - 22, y: w.maxY - 20, width: 18, height: 18)
    }

    /// Окно статуса. Покой (1,0–7,0) — по стене (`o.lag`): с удержанием таймлайн стоит, Capri и печать — нет.
    static func windowForm(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> SceneFrame {
        let text = o.text
        let w = g.area ?? g.target
        let face = faceIn(.window, window: w)
        let eyes = strip(face)
        let line = CGRect(x: eyes.minX, y: eyes.midY - 1, width: eyes.width, height: 2)
        switch t {
        case ..<0.25: return out("out", at: g.home, t, len: 0.25, c)
        case ..<0.4: return jump("jump", from: g.home, to: eyes, t - 0.25, len: 0.15)
        case ..<0.6: return into("in", at: eyes, t - 0.4, len: 0.2, c)
        case ..<1.0:
            // Из линии глаз: рамка растёт по горизонтали, потом по вертикали; лицо раскрывается вместе с ней.
            let p = CGFloat((t - 0.6) / 0.4)
            return unfoldFrame(p, w, face, line, clip: pick([SceneClip.faceTalk, SceneClip.look], c), clipT: t - 0.6, loop: true)
        case ..<7.0:
            // Говорит маской (`face_talk`) крупнее, чем в ответе, и без кивка — голова чуть плывёт вбок; напечатано —
            // зеркальный крупный план глаз, камера плывёт вверх-вниз (у сессий — вбок, без зеркала).
            let tw = t + o.lag
            let typed = min(text, Int(max(0, tw - 1.2) * 18))
            let talking = typed < text
            var f = SceneFrame(phase: "window", eyes: face)
            f.face = SceneFace()
            f.wallClock = true
            if talking {
                f.clip = pick([SceneClip.faceTalk, SceneClip.talk, SceneClip.look], c); f.clipT = tw - 1.0
                if f.clip == SceneClip.faceTalk {
                    f.face?.zoom = 1.12
                    f.face?.shift = CGVector(dx: 0.02 * sin(tw * 1.3), dy: 0.03)
                }
            } else if c.contains(SceneClip.faceScan) {
                f.clip = SceneClip.faceScan; f.clipT = (tw - 1.0) * 0.4; f.clipMode = .bounce
                f.face?.mirror = true
                f.face?.zoom = 1.1
                f.face?.shift = CGVector(dx: 0, dy: 0.03 * sin(tw * 0.8))
            } else {
                f.clip = SceneClip.look; f.clipT = tw - 1.0
            }
            f.glitch = idleGlitch(tw)
            f.window = SceneWindow(rect: w, open: 1, chrome: true, melt: 0, typed: typed,
                                   caret: Int(tw * 2.5) % 2 == 0)
            return f
        case ..<7.6:
            let p = CGFloat((t - 7.0) / 0.6)
            var f = SceneFrame(phase: "melt", eyes: face, clip: c.contains(SceneClip.melt) ? SceneClip.melt : SceneClip.look, clipT: t - 7.0, loop: false)
            f.face = SceneFace()
            f.glitch = c.contains(SceneClip.melt) ? 2 : 4
            f.squash = 1 - 0.8 * max(0, p - 0.5) * 2
            f.window = SceneWindow(rect: w, open: 1, chrome: p < 0.4, melt: p, typed: text, caret: false)
            return f
        case ..<7.75: return jump("back", from: eyes, to: g.home, t - 7.6, len: 0.15)
        default:
            var f = into("home", at: g.home, t - 7.75, len: 0.25, c)
            f.glitch = 2
            return f
        }
    }

    // MARK: C. Захват

    /// Глаза в правом нижнем углу области захвата.
    public static func eyesInArea(_ a: CGRect) -> CGRect {
        CGRect(x: a.maxX - 16 - eyesSize.width, y: a.minY + 16, width: eyesSize.width, height: eyesSize.height)
    }

    /// Точки нарисованного курсора (квадратичные Безье через 3 точки области).
    static func cursorPath(_ a: CGRect, _ u: CGFloat) -> CGPoint {
        let p0 = CGPoint(x: a.minX + a.width * 0.2, y: a.minY + a.height * 0.75)
        let p1 = CGPoint(x: a.minX + a.width * 0.75, y: a.minY + a.height * 0.95)
        let p2 = CGPoint(x: a.minX + a.width * 0.55, y: a.minY + a.height * 0.35)
        let v = 1 - u
        return CGPoint(x: v * v * p0.x + 2 * v * u * p1.x + u * u * p2.x,
                       y: v * v * p0.y + 2 * v * u * p1.y + u * u * p2.y)
    }

    static let clickTimes = [1.8, 2.6, 3.3]

    static func takeover(_ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ lines: [Int]) -> SceneFrame {
        let a = g.area ?? g.target
        let eyes = eyesInArea(a)
        switch t {
        case ..<0.2: return out("out", at: g.home, t, len: 0.2, c)
        case ..<0.35: return jump("jump", from: g.home, to: eyes, t - 0.2, len: 0.15)
        case ..<0.5: return into("in", at: eyes, t - 0.35, len: 0.15, c)
        case ..<3.8:
            let wave = CGFloat(min(1, (t - 0.5) / 0.7))
            var f = SceneFrame(phase: t < 1.2 ? "wave" : "hack", eyes: eyes)
            // Глаза: смотрит, со взлома — много глаз, затем взрыв глаз.
            if t < 1.2 { f.clip = SceneClip.look; f.clipT = t - 0.5 }
            else if t < 2.6 { f.clip = c.contains(SceneClip.many) ? SceneClip.many : SceneClip.look; f.clipT = t - 1.2; f.loop = false }
            else { f.clip = c.contains(SceneClip.burst) ? SceneClip.burst : SceneClip.look; f.clipT = t - 2.6; f.loop = false }
            f.glitch = t >= 3.5 ? 3 : idleGlitch(t)
            var cursor: CGPoint?
            var rings: [SceneRing] = []
            var typed = Array(repeating: 0, count: lines.count)
            if t >= 1.2 {
                let u = CGFloat(min(1, (t - 1.2) / 2.3))
                cursor = cursorPath(a, u)
                for k in clickTimes where t >= k && t < k + 0.45 {
                    rings.append(SceneRing(center: cursorPath(a, CGFloat(min(1, (k - 1.2) / 2.3))),
                                           progress: CGFloat((t - k) / 0.45)))
                }
                // Строки печатаются по очереди, ~22 буквы в секунду.
                var left = (t - 1.4) * 22
                for i in lines.indices {
                    let n = max(0, min(lines[i], Int(left)))
                    typed[i] = n
                    left -= Double(lines[i]) + 4
                }
            }
            let tick = Int(t * 24)
            let edge = t >= 1.6 ? TickNoise.burst(tick, period: 14, length: 3, salt: 41) : nil
            f.takeover = SceneTakeover(area: a, wave: wave, cursor: cursor, rings: rings, typed: typed,
                                       graffiti: CGFloat(max(0, min(1, (t - 2.0) / 0.5))),
                                       edgeBolt: edge, collapse: 1)
            return f
        case ..<4.3:
            let p = CGFloat((t - 3.8) / 0.5)
            var f = SceneFrame(phase: "collapse", eyes: eyes, clip: c.contains(SceneClip.burst) ? SceneClip.burst : SceneClip.look, clipT: t - 2.6, loop: false)
            f.glitch = 4
            f.squash = max(0.04, 1 - p)
            f.takeover = SceneTakeover(area: a, wave: 1, cursor: nil, rings: [], typed: lines, graffiti: 1,
                                       edgeBolt: nil, collapse: max(0.01, 1 - p))
            return f
        case ..<4.45: return jump("back", from: eyes, to: g.home, t - 4.3, len: 0.15)
        default:
            var f = into("home", at: g.home, t - 4.45, len: 0.15, c)
            f.glitch = 2
            return f
        }
    }

    // MARK: D. Вайб на столе

    /// Кивок под музыку: смещение вниз (pt) на сильную долю.
    public static func nod(_ t: Double, amplitude: CGFloat = 4) -> CGFloat {
        let beat = t * bpm / 60
        let phase = beat - floor(beat)
        // Быстро вниз на долю, плавно вверх.
        return amplitude * CGFloat(phase < 0.2 ? phase / 0.2 : 1 - (phase - 0.2) / 0.8)
    }

    /// Сильная доля: щёлки вместо открытых глаз.
    public static func onBeat(_ t: Double) -> Bool {
        let beat = t * bpm / 60
        return beat - floor(beat) < 0.18
    }

    static func vibe(_ t: Double, _ g: SceneGeometry, _ c: Set<String>) -> SceneFrame {
        switch t {
        case ..<0.25: return out("out", at: g.home, t, len: 0.25, c)
        case ..<0.4: return jump("jump", from: g.home, to: g.target, t - 0.25, len: 0.15)
        case ..<0.75: return into("in", at: g.target, t - 0.4, len: 0.35, c)
        case ..<6.5:
            let k = t - 0.75
            var f = SceneFrame(phase: "vibe", eyes: g.target.offsetBy(dx: 0, dy: -nod(k)))
            f.clip = onBeat(k) && c.contains(SceneClip.slits) ? SceneClip.slits : SceneClip.look
            f.clipT = onBeat(k) ? 0.4 : k
            f.loop = true
            f.glitch = k.truncatingRemainder(dividingBy: 60 / bpm * 8) < 0.08 ? 1 : 0
            // Ноты: всплывают над глазами раз в долю, живут 1.6 с.
            let beatLen = 60 / bpm
            let first = max(0, Int((k - 1.6) / beatLen) + 1)
            for i in first...max(first, Int(k / beatLen)) where Double(i) * beatLen <= k {
                let age = (k - Double(i) * beatLen) / 1.6
                guard age < 1 else { continue }
                let side: CGFloat = i % 2 == 0 ? -1 : 1
                let x = g.target.midX + side * (g.target.width * 0.35 + CGFloat(TickNoise.unit(i, 51)) * 18)
                let y = g.target.maxY + 4 + CGFloat(age) * 46
                f.notes.append(SceneNote(center: CGPoint(x: x + CGFloat(sin(age * 6)) * 4, y: y),
                                         alpha: CGFloat(age < 0.2 ? age / 0.2 : 1 - (age - 0.2) / 0.8), glyph: i % 3))
            }
            return f
        case ..<6.75: return out("leave", at: g.target, t - 6.5, len: 0.25, c)
        case ..<6.9: return jump("back", from: g.target, to: g.home, t - 6.75, len: 0.15)
        default:
            var f = into("home", at: g.home, t - 6.9, len: 0.1, c)
            f.glitch = 2
            return f
        }
    }

    // MARK: обрыв

    /// Где были глаза в момент обрыва (или центр цели, если их не было на столе).
    static func eyesAt(_ kind: SceneKind, _ t: Double, _ g: SceneGeometry, _ c: Set<String>, _ o: SceneOptions) -> CGRect {
        frame(kind, t: t, geometry: g, clips: c, options: o).eyes ?? g.target
    }

    /// Сцена с крупным лицом (aspect-fill): окна и `reply`. Показ держит у них 12 fps и при удержании.
    public static func usesFace(_ kind: SceneKind) -> Bool { kind.boxed || kind == .reply }

    static func recall(_ kind: SceneKind, t: Double, at a: Double, geometry g: SceneGeometry, clips: Set<String>,
                       options o: SceneOptions) -> SceneFrame {
        let k = t - a
        guard k < recallDuration else { return .home("recalled") }
        let from = eyesAt(kind, a, g, clips, o)
        if k < 0.1 {
            var f = SceneFrame(phase: "recall", eyes: from, glitch: 4)
            f.squash = CGFloat(max(0.05, 1 - k / 0.1))
            if usesFace(kind) { f.face = SceneFace() }
            return f
        }
        return jump("recall", from: from, to: g.home, k - 0.1, len: recallDuration - 0.1)
    }
}

/// Куда идёт персонаж: чистая геометрия по прямоугольникам экрана и окон.
public enum SceneLayout {
    public static let margin: CGFloat = 24

    /// Правый нижний угол `visible` с отступом.
    public static func corner(_ visible: CGRect, size: CGSize) -> CGRect {
        clamp(CGRect(x: visible.maxX - margin - size.width, y: visible.minY + margin, width: size.width, height: size.height),
              to: visible)
    }

    /// Прямоугольник внутри `visible` (сдвигом; если не влезает — по размеру `visible`).
    public static func clamp(_ r: CGRect, to visible: CGRect) -> CGRect {
        let w = min(r.width, visible.width), h = min(r.height, visible.height)
        let x = min(max(r.minX, visible.minX), visible.maxX - w)
        let y = min(max(r.minY, visible.minY), visible.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// CG (от верхнего левого угла главного экрана) → AppKit (от нижнего левого).
    public static func appKit(_ cg: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    /// «Сидит на окне»: глаза на верхнем крае окна справа. Только если окно целиком на экране и между ним и
    /// строкой меню есть место под глаза; иначе nil (тогда — угол).
    public static func onWindow(_ window: CGRect, visible: CGRect, size: CGSize = SceneTimeline.eyesSize) -> CGRect? {
        guard visible.contains(window.insetBy(dx: 1, dy: 1)), window.width >= size.width + 80, window.height >= 120,
              window.maxY + size.height * 0.75 + 8 <= visible.maxY else { return nil }
        return CGRect(x: window.maxX - 48 - size.width, y: window.maxY - size.height * 0.25,
                      width: size.width, height: size.height)
    }

    /// Область захвата: рамка окна терминала (обрезанная экраном), если она не крошечная; иначе угол 480×300.
    public static func takeoverArea(window: CGRect?, visible: CGRect) -> CGRect {
        if let w = window?.intersection(visible), !w.isNull, w.width >= 240, w.height >= 160 { return w }
        return corner(visible, size: SceneTimeline.takeoverSize)
    }

    /// Окно Capri в правом нижнем углу.
    public static func windowForm(_ visible: CGRect) -> CGRect {
        corner(visible, size: SceneTimeline.windowSize)
    }

    /// Терминалы, над которыми можно изображать «захват» (bundle id переднего приложения).
    public static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable",
    ]
}
