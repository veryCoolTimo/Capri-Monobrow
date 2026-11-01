import Foundation
import CoreGraphics

/// Конечность тела в полный рост: абсолютные углы сегментов в градусах экрана (y вниз: 0° — вправо, 90° — вниз,
/// −90° — вверх). Рука: плечо, предплечье, кисть. Нога: бедро, голень, стопа-шип.
public struct BodyLimb: Equatable {
    public var upper: Double
    public var lower: Double
    public var end: Double
    /// Веер пальцев-шипов (градусы); у ноги не используется.
    public var spread: Double
    /// Ракурс первого сегмента: 1 — в плоскости, меньше — уходит к зрителю (бедро сидящей).
    public var reach: Double

    public init(_ upper: Double = 90, _ lower: Double = 90, _ end: Double = 90, spread: Double = 30, reach: Double = 1) {
        self.upper = upper; self.lower = lower; self.end = end; self.spread = spread; self.reach = reach
    }

    public static let down = BodyLimb()

    public static func mix(_ a: BodyLimb, _ b: BodyLimb, _ k: Double) -> BodyLimb {
        BodyLimb(lerp(a.upper, b.upper, k), lerp(a.lower, b.lower, k), lerp(a.end, b.end, k),
                 spread: lerp(a.spread, b.spread, k), reach: lerp(a.reach, b.reach, k))
    }
}

/// Поза тела Capri в полный рост. Координаты сцены — в пунктах при масштабе 1, y вниз; у каждого движения
/// (`BodyMoves`) свой ноль (край окна, пол). Индекс конечности 0 — левая на экране, 1 — правая.
public struct BodyPose: Equatable {
    /// Талия — корень скелета.
    public var waist = CGPoint.zero
    /// Абсолютный угол груди (−90 — прямо вверх) и таза (90 — прямо вниз).
    public var chest = -90.0
    public var pelvis = 90.0
    /// Шея относительно груди, голова относительно шеи.
    public var neck = 0.0
    public var head = 0.0
    public var arms = [BodyLimb(100, 92, 90, spread: 26), BodyLimb(80, 88, 90, spread: 26)]
    public var legs = [BodyLimb(93, 91, 92), BodyLimb(87, 89, 88)]
    /// Цели IK (запястье / щиколотка) и сторона сгиба: +1 — сустав по часовой от линии корень→цель (на экране).
    public var handAt: [CGPoint?] = [nil, nil]
    public var footAt: [CGPoint?] = [nil, nil]
    public var elbowBend = [-1.0, 1.0]
    public var kneeBend = [1.0, -1.0]
    /// Пришпилить скелет: после FK всё сдвигается так, чтобы этот сустав оказался в `pinAt`.
    public var pin: BodyJoint?
    public var pinAt = CGPoint.zero
    /// Ближняя сторона (её рука и нога — поверх туловища): −1 левая, +1 правая.
    public var near = 1
    /// Лицо: выражение маски из мини-рига (глаза, рот, взгляд, поворот).
    public var face = RigPose(eyes: .open, mouth: .fang)
    /// Масса волос (масштаб), покачивание, «подброс» (+ вверх, − повисли).
    public var hair = 1.0
    public var sway = 1.0
    public var lift = 0.0
    /// Наклон всей массы волос относительно головы (градусы; висит на руке — масса падает в сторону).
    public var hairTilt = 0.0
    /// Дыхание −1…1: плечи и грудь.
    public var breath = 0.0
    /// 0…1 — растекается лужей к `ground`, 1…2 — лужа уползает в сторону `leaveDir` и тает.
    public var melt = 0.0
    public var ground = 0.0
    public var leaveDir = 1.0
    /// Силуэт в контровом свете 0…1.
    public var backlit = 0.0
    /// Сторона, откуда фиолетовая кромка (сдвиг копии), в пунктах.
    public var rim = CGVector(dx: -0.8, dy: 0.5)
    /// Зеркально по x относительно талии.
    public var flip = false
    /// Время (с) — покачивание волос; кадр 12 fps — блёстки.
    public var t = 0.0
    public var tick = 0
    public var seed = 0

    public init() {}
}

/// Суставы, которые можно пришпилить к точке сцены.
public enum BodyJoint: Equatable {
    case wrist(Int), ankle(Int), toe(Int), fingertip(Int), waist, seat
}

/// Решённый скелет: точки суставов и углы костей (градусы) в координатах сцены.
public struct BodySkeleton: Equatable {
    public var waist: CGPoint
    public var chest: Double, pelvis: Double, neck: Double, head: Double
    public var neckBase: CGPoint, headBase: CGPoint
    public var shoulders: [CGPoint], elbows: [CGPoint], wrists: [CGPoint], handEnds: [CGPoint]
    public var hips: [CGPoint], knees: [CGPoint], ankles: [CGPoint], toes: [CGPoint]
    public var arms: [BodyLimb], legs: [BodyLimb]
    /// Низ таза (на нём сидят).
    public var seat: CGPoint

    public func point(_ j: BodyJoint) -> CGPoint {
        switch j {
        case .wrist(let i): wrists[i]
        case .ankle(let i): ankles[i]
        case .toe(let i): toes[i]
        case .fingertip(let i): handEnds[i]
        case .waist: waist
        case .seat: seat
        }
    }

    mutating func shift(_ d: CGVector) {
        func m(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + d.dx, y: p.y + d.dy) }
        waist = m(waist); neckBase = m(neckBase); headBase = m(headBase); seat = m(seat)
        shoulders = shoulders.map(m); elbows = elbows.map(m); wrists = wrists.map(m); handEnds = handEnds.map(m)
        hips = hips.map(m); knees = knees.map(m); ankles = ankles.map(m); toes = toes.map(m)
    }
}

/// Двухзвенный IK и мелкая угловая математика.
public enum BodyIK {
    public static func dir(_ deg: Double) -> CGVector {
        let r = deg * .pi / 180
        return CGVector(dx: cos(r), dy: sin(r))
    }

    public static func angle(_ a: CGPoint, _ b: CGPoint) -> Double { atan2(Double(b.y - a.y), Double(b.x - a.x)) * 180 / .pi }

    public static func step(_ p: CGPoint, _ deg: Double, _ len: Double) -> CGPoint {
        let d = dir(deg)
        return CGPoint(x: p.x + d.dx * CGFloat(len), y: p.y + d.dy * CGFloat(len))
    }

    /// Углы двух звеньев длиной `l1`, `l2` от `root` к `target`. Недостижимая цель — тянется прямой рукой к ней;
    /// слишком близкая — сустав складывается до предела. `bend` +1 — сустав по часовой стрелке (на экране, y вниз)
    /// от линии корень→цель.
    public static func solve(root: CGPoint, target: CGPoint, l1: Double, l2: Double, bend: Double) -> (Double, Double) {
        let dx = Double(target.x - root.x), dy = Double(target.y - root.y)
        let raw = hypot(dx, dy)
        let base = raw < 1e-9 ? 90 : atan2(dy, dx) * 180 / .pi
        let lo = abs(l1 - l2) + 1e-6, hi = l1 + l2 - 1e-6
        let d = min(max(raw, lo), hi)
        let cosA = max(-1, min(1, (l1 * l1 + d * d - l2 * l2) / (2 * l1 * d)))
        let a = acos(cosA) * 180 / .pi
        let a1 = base + (bend >= 0 ? 1 : -1) * a
        let joint = step(root, a1, l1)
        let reach = step(root, base, d)
        let a2 = angle(joint, reach)
        return (a1, a2)
    }

    /// Разность углов в (−180, 180].
    public static func delta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    /// Плавная ступень 0…1.
    public static func smooth(_ x: Double) -> Double {
        let k = max(0, min(1, x))
        return k * k * (3 - 2 * k)
    }
}

extension BodyPose {
    /// Массивы по сторонам ровно на две стороны (битая поза из `mix`/`zip` не роняет сборку).
    public var normalized: BodyPose {
        var o = self
        func two<T>(_ x: [T], _ d: T) -> [T] { Array((x + [d, d]).prefix(2)) }
        o.arms = two(arms, BodyLimb.down); o.legs = two(legs, BodyLimb.down)
        o.handAt = two(handAt, nil); o.footAt = two(footAt, nil)
        o.elbowBend = two(elbowBend, 1.0); o.kneeBend = two(kneeBend, 1.0)
        return o
    }

    /// Смесь поз: числа — линейно (углы — по кратчайшей дуге), цели IK — если есть у обеих.
    public static func mix(_ a: BodyPose, _ b: BodyPose, _ k: Double) -> BodyPose {
        let k = max(0, min(1, k))
        var o = k < 0.5 ? a : b
        func ang(_ x: Double, _ y: Double) -> Double { x + BodyIK.delta(x, y) * k }
        func pt(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * k, y: p.y + (q.y - p.y) * k) }
        func limb(_ p: BodyLimb, _ q: BodyLimb) -> BodyLimb {
            BodyLimb(ang(p.upper, q.upper), ang(p.lower, q.lower), ang(p.end, q.end), spread: lerp(p.spread, q.spread, k),
                     reach: lerp(p.reach, q.reach, k))
        }
        o.waist = pt(a.waist, b.waist)
        o.chest = ang(a.chest, b.chest); o.pelvis = ang(a.pelvis, b.pelvis)
        o.neck = lerp(a.neck, b.neck, k); o.head = lerp(a.head, b.head, k)
        o.arms = zip(a.arms, b.arms).map { limb($0, $1) }
        o.legs = zip(a.legs, b.legs).map { limb($0, $1) }
        o.handAt = zip(a.handAt, b.handAt).map { p, q in p.flatMap { p in q.map { pt(p, $0) } } }
        o.footAt = zip(a.footAt, b.footAt).map { p, q in p.flatMap { p in q.map { pt(p, $0) } } }
        // Пришпилены разные суставы — точку не смешиваем (иначе сустав А тянется к точке Б).
        o.pinAt = a.pin == b.pin ? pt(a.pinAt, b.pinAt) : o.pinAt
        o.face = RigPose.mix(a.face, b.face, k)
        o.hairTilt = lerp(a.hairTilt, b.hairTilt, k); o.hair = lerp(a.hair, b.hair, k); o.lift = lerp(a.lift, b.lift, k); o.breath = lerp(a.breath, b.breath, k)
        o.melt = lerp(a.melt, b.melt, k); o.backlit = lerp(a.backlit, b.backlit, k)
        return o
    }
}
