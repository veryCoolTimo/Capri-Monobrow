import Foundation
import CoreGraphics

/// Общая библиотека переходов: все сцены входят и выходят через один набор эффектов (библия: полосы со сдвигом и
/// RGB-разносом, вертикальный «размаз» столбцами, вспышка сплошным цветом, уход лентой, молния (путь из коротких
/// прямых отрезков с ответвлениями). Чистые функции времени и зерна — живой показ и листы дают одинаковые кадры;
/// показ (`CapriEffects`) только рисует `TransitionFrame`.
public enum TransitionKind: String, CaseIterable, Codable {
    /// Вход из вспышки сплошного цвета (малиновый волос / зелёная маска), потом проявление полосами.
    case burstIn
    /// Проявление/распад горизонтальными полосами со сдвигом и RGB-разносом.
    case glitchBars
    /// Кадр «стекает» (уход) или «натекает» сверху (вход) вертикальными столбцами.
    case columnSmear
    /// Уход лентой: глаза сплющиваются в линию, лента волос летит к цели.
    case ribbonOut
    /// Перелёт: молния (концы и «кипение»; рисуется розовой иглой `TransitionArt.drawBolt`).
    case boltChain
}

public enum TransitionRole: String, Codable {
    /// Появиться в `to`.
    case enter
    /// Исчезнуть из `from` (лента — в сторону `to`).
    case exit
}

/// Горизонтальная полоса кадра: верх и высота — доли высоты прямоугольника (0 — верх), сдвиг и RGB-разнос — pt.
public struct TransitionBar: Equatable {
    public var y: CGFloat
    public var h: CGFloat
    public var dx: CGFloat
    public var split: CGFloat
    public var shown: Bool
}

/// Вертикальный столбец кадра: лево и ширина — доли ширины; сдвиг вниз (pt, < 0 — вверх) и растяжение по высоте.
public struct TransitionColumn: Equatable {
    public var x: CGFloat
    public var w: CGFloat
    public var drop: CGFloat
    public var stretch: CGFloat
    public var shown: Bool
}

/// Цвет вспышки: волосы `#FB0D49` или маска `#00FC67`.
public enum FlashTint: Int, Codable { case hair, mask }

/// Вспышка сплошным цветом (рваный силуэт вокруг `rect`).
public struct TransitionFlash: Equatable {
    public var rect: CGRect
    public var tint: FlashTint
    public var alpha: CGFloat
    /// Форма рваного края.
    public var seed: Int
}

/// Лента: ломаная от глаз к цели; видна часть между `tail` и `head` (доли длины).
public struct TransitionRibbon: Equatable {
    public var points: [CGPoint]
    public var width: CGFloat
    public var head: CGFloat
    public var tail: CGFloat
}

public struct BoltSegment: Equatable {
    public var a: CGPoint
    public var b: CGPoint
    public var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
}

/// Молния: главный путь (вершины) и ответвления (каждое начинается в вершине главного пути).
public struct TransitionBolt: Equatable {
    public var main: [CGPoint]
    public var branches: [[CGPoint]]

    /// Все прямые отрезки (главный путь, затем ответвления).
    public var segments: [BoltSegment] {
        ([main] + branches).flatMap { pts in zip(pts, pts.dropFirst()).map { BoltSegment(a: $0, b: $1) } }
    }
}

/// Кадр перехода: где и как рисовать содержимое (глаза/лицо) и что поверх.
public struct TransitionFrame: Equatable {
    public var kind: TransitionKind
    public var role: TransitionRole
    public var progress: CGFloat
    /// Где рисуется содержимое; nil — не рисуется.
    public var rect: CGRect?
    /// 1 — обычная высота, → 0 — сплющено в линию.
    public var squash: CGFloat = 1
    /// Пусто — содержимое целиком; иначе — только эти полосы/столбцы.
    public var bars: [TransitionBar] = []
    public var columns: [TransitionColumn] = []
    public var flash: TransitionFlash?
    public var ribbon: TransitionRibbon?
    public var bolt: TransitionBolt?

    /// Содержимое просто стоит на месте — рисовать как без перехода.
    public var plain: Bool {
        rect != nil && squash == 1 && bars.isEmpty && columns.isEmpty && flash == nil && ribbon == nil && bolt == nil
    }

    /// Ничего не видно.
    public var hidden: Bool { rect == nil && flash == nil && ribbon == nil && bolt == nil }
}

public enum Transitions {
    /// Длина отрезка молнии (целевая) и потолок — прямые короткие отрезки, как в сериале.
    public static let segmentTarget: CGFloat = 34
    public static let segmentMax: CGFloat = 60

    /// Чем можно войти/выйти. Молния — перелёт между ними, не вход и не выход.
    public static func options(_ role: TransitionRole) -> [TransitionKind] {
        switch role {
        case .enter: [.burstIn, .glitchBars, .columnSmear]
        case .exit: [.glitchBars, .columnSmear, .ribbonOut]
        }
    }

    /// Выбор вида по зерну, не повторяя предыдущий (`avoid`). Reduce Motion — только полосы (без вспышек).
    public static func pick(_ role: TransitionRole, seed: Int, avoid: TransitionKind? = nil, reduceMotion: Bool = false) -> TransitionKind {
        if reduceMotion { return .glitchBars }
        let opts = options(role).filter { $0 != avoid }
        return opts[Int(TickNoise.hash(seed, role == .enter ? 1301 : 1302) % UInt64(opts.count))]
    }

    /// Начало перехода: вход — ничего нет, выход — содержимое на месте.
    public static func start(_ kind: TransitionKind, _ role: TransitionRole, from: CGRect, to: CGRect) -> TransitionFrame {
        TransitionFrame(kind: kind, role: role, progress: 0, rect: kind != .boltChain && role == .exit ? from : nil)
    }

    /// Конец перехода: вход — содержимое на месте, выход и молния — ничего нет.
    public static func end(_ kind: TransitionKind, _ role: TransitionRole, from: CGRect, to: CGRect) -> TransitionFrame {
        TransitionFrame(kind: kind, role: role, progress: 1, rect: kind != .boltChain && role == .enter ? to : nil)
    }

    /// Кадр в момент `t` перехода длиной `len` (тик 24 fps — для «кипения» полос и молнии).
    public static func frame(_ kind: TransitionKind, _ role: TransitionRole, t: Double, len: Double, from: CGRect, to: CGRect,
                             seed: Int, reduceMotion: Bool = false) -> TransitionFrame {
        let p = len > 0 ? CGFloat(t / len) : 1
        return frame(kind, role, progress: p, tick: Int(max(0, t) * 24), from: from, to: to, seed: seed, reduceMotion: reduceMotion)
    }

    public static func frame(_ kind: TransitionKind, _ role: TransitionRole, progress p: CGFloat, tick: Int, from: CGRect, to: CGRect,
                             seed: Int, reduceMotion: Bool = false) -> TransitionFrame {
        if p <= 0 { return start(kind, role, from: from, to: to) }
        if p >= 1 { return end(kind, role, from: from, to: to) }
        // Вход — тот же выход задом наперёд: q — доля «ушедшего».
        let q = role == .exit ? p : 1 - p
        let at = role == .exit ? from : to
        var f = TransitionFrame(kind: kind, role: role, progress: p, rect: at)
        switch kind {
        case .glitchBars:
            f.bars = bars(at, q: q, tick: tick, seed: seed)
        case .columnSmear:
            f.columns = columns(at, q: q, seed: seed, up: role == .enter)
        case .burstIn:
            if role == .exit || reduceMotion {
                f.bars = bars(at, q: q, tick: tick, seed: seed)
                break
            }
            // 0–0,2: сплошная вспышка (1–2 кадра), глаз нет; дальше — проявление полосами.
            let flashEnd: CGFloat = 0.2
            if p < flashEnd {
                f.rect = nil
            } else {
                f.bars = bars(at, q: 1 - (p - flashEnd) / (1 - flashEnd), tick: tick, seed: seed)
            }
            let a = p < flashEnd ? 1 : max(0, 1 - (p - flashEnd) / 0.1)
            if a > 0 {
                f.flash = TransitionFlash(rect: at.insetBy(dx: -at.width * 0.3, dy: -at.height * 0.55),
                                          tint: TickNoise.unit(seed, 1310) < 0.5 ? .hair : .mask, alpha: a, seed: seed)
            }
        case .ribbonOut:
            if role == .enter {
                f.bars = bars(at, q: q, tick: tick, seed: seed)
                break
            }
            // 0–0,3: сплющивается в линию; дальше глаз нет — лента от глаз к цели (голова впереди, хвост догоняет).
            if p < 0.3 {
                f.squash = max(0.06, 1 - p / 0.3 * 0.94)
            } else {
                f.rect = nil
                let head = min(1, (p - 0.3) / 0.5), tail = max(0, min(1, (p - 0.45) / 0.55))
                if tail < head {
                    f.ribbon = TransitionRibbon(points: ribbonPath(from: center(from), to: center(to), seed: seed),
                                                width: max(6, min(from.height * 0.45, 22)), head: head, tail: tail)
                }
            }
        case .boltChain:
            f.rect = nil
            f.bolt = bolt(from: center(from), to: center(to), seed: seed &+ tick / 2, reach: min(1, p / 0.7))
        }
        return f
    }

    static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    /// Полосы во всю высоту `r` (без щелей); полоса `i` пропадает, когда `q` проходит её порог. Сдвиг растёт с `q`
    /// и «кипит» каждый тик.
    static func bars(_ r: CGRect, q: CGFloat, tick: Int, seed: Int) -> [TransitionBar] {
        let n = 7 + Int(TickNoise.hash(seed, 1320) % 5)
        let weights = (0..<n).map { 0.4 + CGFloat(TickNoise.unit(seed &+ $0, 1321)) }
        let total = weights.reduce(0, +)
        var y: CGFloat = 0
        return (0..<n).map { i in
            let h = weights[i] / total
            defer { y += h }
            let threshold = 0.2 + 0.7 * CGFloat(TickNoise.unit(seed &+ i, 1322))
            let side: CGFloat = TickNoise.unit(seed &+ i, 1323) < 0.5 ? -1 : 1
            let jitter = 0.5 + CGFloat(TickNoise.unit(tick &+ i * 31, 1324 &+ seed))
            let dx = side * r.width * 0.4 * pow(q, 1.4) * jitter
            return TransitionBar(y: y, h: h, dx: dx, split: 1.5 + 6 * q, shown: q < threshold)
        }
    }

    /// Столбцы: каждый «стекает» (или натекает сверху, `up`) со своей задержкой, растягиваясь по высоте.
    static func columns(_ r: CGRect, q: CGFloat, seed: Int, up: Bool) -> [TransitionColumn] {
        let n = 10 + Int(TickNoise.hash(seed, 1330) % 7)
        let w = 1 / CGFloat(n)
        return (0..<n).map { i in
            let delay = 0.45 * CGFloat(TickNoise.unit(seed &+ i, 1331))
            let k = max(0, min(1, (q - delay) / 0.55))
            let drop = k * k * r.height * 1.1 * (up ? -1 : 1)
            return TransitionColumn(x: CGFloat(i) * w, w: w, drop: drop, stretch: 1 + 1.5 * k, shown: k < 1)
        }
    }

    /// Ломаная ленты (16 точек): дуга от `a` к `b` с изгибом вбок по зерну.
    static func ribbonPath(from a: CGPoint, to b: CGPoint, seed: Int) -> [CGPoint] {
        let dx = b.x - a.x, dy = b.y - a.y, len = max(1, hypot(dx, dy))
        let bend = (CGFloat(TickNoise.unit(seed, 1340)) - 0.5) * 2 * min(160, len * 0.35)
        let c = CGPoint(x: (a.x + b.x) / 2 - dy / len * bend, y: (a.y + b.y) / 2 + dx / len * bend)
        return (0...15).map { k in
            let u = CGFloat(k) / 15, v = 1 - u
            let wa: CGFloat = v * v, wc: CGFloat = 2 * v * u, wb: CGFloat = u * u
            let x: CGFloat = wa * a.x + wc * c.x + wb * b.x
            let y: CGFloat = wa * a.y + wc * c.y + wb * b.y
            return CGPoint(x: x, y: y)
        }
    }

    /// Молния `a → b` (рисуется розовой иглой): прямые отрезки ≈ 34 pt со сдвигом вбок, 1–3 ответвления по 2–3 отрезка. `reach` —
    /// какая доля пути уже пройдена (ответвления — только из пройденной части). nil — пути нет.
    public static func bolt(from a: CGPoint, to b: CGPoint, seed: Int, reach: CGFloat = 1) -> TransitionBolt? {
        let dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy)
        guard len > 1, reach > 0 else { return nil }
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let n = max(3, Int((len / segmentTarget).rounded(.up)))
        let base = len / CGFloat(n)
        var pts = [a]
        for k in 1..<n {
            let along = len * CGFloat(k) / CGFloat(n) + (CGFloat(TickNoise.unit(seed &+ k, 1350)) - 0.5) * base * 0.3
            let off = (CGFloat(TickNoise.unit(seed &+ k, 1351)) - 0.5) * 2 * base * 0.45
            pts.append(CGPoint(x: a.x + ux * along + nx * off, y: a.y + uy * along + ny * off))
        }
        pts.append(b)
        // Обрезка по пройденной доле длины.
        let main = cut(pts, at: max(0, min(1, reach)))
        var branches: [[CGPoint]] = []
        let count = n >= 4 ? 1 + Int(TickNoise.hash(seed, 1352) % 3) : 0
        for j in 0..<count {
            let i = 1 + Int(TickNoise.hash(seed &+ j, 1353) % UInt64(n - 1))
            guard i < main.count - 1 else { continue }
            let side: CGFloat = TickNoise.unit(seed &+ j, 1354) < 0.5 ? -1 : 1
            var ang = atan2(uy, ux) + side * (0.4 + 0.6 * CGFloat(TickNoise.unit(seed &+ j, 1355)))
            var p = main[i]
            var branch = [p]
            for s in 0..<(2 + Int(TickNoise.hash(seed &+ j, 1356) % 2)) {
                let l = base * (0.5 + 0.4 * CGFloat(TickNoise.unit(seed &+ j * 7 + s, 1357)))
                p = CGPoint(x: p.x + cos(ang) * l, y: p.y + sin(ang) * l)
                branch.append(p)
                ang += (CGFloat(TickNoise.unit(seed &+ j * 7 + s, 1358)) - 0.5) * 1.0
            }
            branches.append(branch)
        }
        return TransitionBolt(main: main, branches: branches)
    }

    /// Начало ломаной до доли `f` её длины (последняя точка — на отрезке).
    static func cut(_ pts: [CGPoint], at f: CGFloat) -> [CGPoint] {
        guard f < 1, pts.count > 1 else { return pts }
        let lens = zip(pts, pts.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var left = lens.reduce(0, +) * f
        var out = [pts[0]]
        for (i, l) in lens.enumerated() {
            if left >= l { out.append(pts[i + 1]); left -= l; continue }
            let k = l > 0 ? left / l : 0
            out.append(CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * k, y: pts[i].y + (pts[i + 1].y - pts[i].y) * k))
            break
        }
        return out
    }
}

// MARK: окно краснеет и стекает столбцами (терминал с Claude)

/// Столбец «размаза» по окну: лево и ширина — доли ширины окна; верх и низ красного — доли высоты от верхнего края
/// (низ > 1 — капля стекла ниже окна).
public struct SmearColumn: Equatable {
    public var x: CGFloat
    public var w: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
}

/// Красные капли по верхнему краю окна (только рисунок, само окно не трогаем): узкая полоса под местом посадки.
public struct WindowSmear: Equatable {
    /// Полоса капель (доли столбцов — от неё).
    public var rect: CGRect
    /// Само окно: капли не вылезают за него.
    public var clip: CGRect
    public var columns: [SmearColumn]
    /// Красный налёт на всё окно 0…1 (под столбцами).
    public var tint: CGFloat
    public var alpha: CGFloat
}

extension Transitions {
    /// Полоса ширины ≤ `stripWidth` и глубины ≤ `stripDepth` у верхнего края окна под `x` (где она вылезет).
    public static let stripWidth: CGFloat = 180
    public static let stripDepth: CGFloat = 54
    public static func smearStrip(window r: CGRect, under x: CGFloat?) -> CGRect {
        let w = min(r.width, stripWidth)
        let h = min(r.height * 0.3, stripDepth)
        let cx = min(max(x ?? r.midX, r.minX + w / 2), r.maxX - w / 2)
        return CGRect(x: cx - w / 2, y: r.maxY - h, width: w, height: h)
    }

    /// Отзыв: сплошная красная завеса на всё окно терминала — самое громкое место сборки, и ровно тогда, когда человек
    /// хочет туда смотреть. Теперь — короткие полупрозрачные капли в узкой полосе у верхнего края окна, под местом,
    /// где она вылезет. Столбцы натекают сверху (каждый со своей задержкой) и стекают — к `p` = 1 их не видно.
    /// 0–0,45 — натекает, 0,45–1 — верх столбцов догоняет низ, капли уходят за низ полосы ≤ 12 %.
    public static func windowSmear(_ window: CGRect, progress p: CGFloat, seed: Int, under x: CGFloat? = nil) -> WindowSmear? {
        guard p > 0, p < 1, window.width > 0, window.height > 0 else { return nil }
        let r = smearStrip(window: window, under: x)
        let n = 9 + Int(TickNoise.hash(seed, 1360) % 5)
        // Разная ширина столбцов: веса 0,3…1,7.
        let weights = (0..<n).map { 0.3 + 1.4 * CGFloat(TickNoise.unit(seed &+ $0, 1361)) }
        let total = weights.reduce(0, +)
        var x: CGFloat = 0
        var cols: [SmearColumn] = []
        for i in 0..<n {
            let w = weights[i] / total
            defer { x += w }
            let delay = 0.18 * CGFloat(TickNoise.unit(seed &+ i, 1362))
            let reach = 0.85 + 0.27 * CGFloat(TickNoise.unit(seed &+ i, 1363))
            let fill = ease(max(0, min(1, (p - delay) / 0.4)))
            let drain = ease(max(0, min(1, (p - 0.45 - delay * 0.8) / 0.45)))
            let bottom = fill * reach + drain * (1.12 - reach) * (TickNoise.unit(seed &+ i, 1364) < 0.6 ? 1 : 0.4)
            let top = drain * max(bottom, 1.0)
            guard bottom - top > 0.004 else { continue }
            cols.append(SmearColumn(x: x, w: w, top: top, bottom: max(top, bottom)))
        }
        // Без налёта на всё окно; капли полупрозрачные.
        return WindowSmear(rect: r, clip: window, columns: cols, tint: 0, alpha: 0.72 * (p > 0.85 ? (1 - p) / 0.15 : 1))
    }

    static func ease(_ x: CGFloat) -> CGFloat { x * x * (3 - 2 * x) }
}
