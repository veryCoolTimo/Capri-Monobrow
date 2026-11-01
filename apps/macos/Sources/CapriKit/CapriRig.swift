import Foundation
import CoreGraphics

/// Цвет слоя рига. Роль → цвет задаёт отрисовка (`Capri/RigView.swift`): маска, чернила, белый рот, зрачок…
public enum RigInk: String, Codable, CaseIterable {
    case mask, ink, white, pupil, ring, hair, rim, sparkle, glint
    /// Пиксельный призрак: светлый, тёмный, красный.
    case ghostLight, ghostDark, ghostRed, stripe
}

/// Готовая к заливке фигура: слой (для тестов и отладки), цвет, многоугольник в координатах рига (y вниз).
public struct RigShape: Equatable {
    public var layer: String
    public var ink: RigInk
    public var points: [CGPoint]
    public var opacity: Double = 1

    public init(_ layer: String, _ ink: RigInk, _ points: [CGPoint], opacity: Double = 1) {
        self.layer = layer; self.ink = ink; self.points = points; self.opacity = opacity
    }

    public var bounds: CGRect { RigGeometry.bounds(points) }
}

/// Векторная модель мини-маски Capri: плоские многоугольники без обводки (пластина, «чёлка», глаз, рты, рука,
/// осколки волос). Только данные — что нарисовать в позе `RigPose`, решает `compose`. Координаты — в коробке
/// `box` (по умолчанию 120×60, как полоса глаз сцены), y вниз; правый глаз и правая рука — зеркало левых по
/// середине коробки.
///
/// В репозитории — только код и простой фолбэк (`fallback`, своя геометрия без рисунка сериала). Рисунок «по
/// мотивам» лежит локально в `~/.capri/art/capri-rig.json` (решение Тимофея) и грузится `load(_:)`.
public struct CapriRig: Codable, Equatable {
    public typealias P = [Double]

    public struct Eye: Codable, Equatable {
        /// Миндаль левого глаза (выпуклый: по нему режется зрачок).
        public var shape: [P]
        /// Чёрный «росчерк» у внешнего угла (может не быть).
        public var tick: [P]?
        /// Центр зрачка при взгляде прямо.
        public var center: P
        /// Радиусы: зрачок (синий), кольцо (зелёное), блик (белый); смещение блика.
        public var pupil: Double
        public var ring: Double
        public var glint: Double
        public var glintAt: P
        /// Насколько зрачок ходит по x/y при взгляде −1…1.
        public var travel: P
    }

    public struct Arm: Codable, Equatable {
        /// Плечо левой руки (правая — зеркало).
        public var shoulder: P
        public var upper: Double
        public var fore: Double
        public var width: Double
        public var finger: Double
        public var fingers: Int
    }

    public struct Shard: Codable, Equatable {
        public var points: [P]
        /// Точка, вокруг которой осколок покачивается.
        public var pivot: P
    }

    public var version: Int
    public var name: String
    public var box: P
    /// Пластина анфас и «значок» (то же число точек — морф).
    public var plate: [P]
    public var badge: [P]
    /// Чёрные зубцы «чёлки» поверх пластины.
    public var spikes: [[P]]
    public var eye: Eye
    /// Рты: клык, зигзаг (ломаная), челюсть-осколок, акулья пасть (тёмный фон + зубы).
    public var fang: [P]
    public var mutter: [P]
    public var jaw: [P]
    public var shark: [P]
    public var teeth: [[P]]
    public var arm: Arm
    public var hair: [Shard]

    public init(version: Int = 1, name: String, box: P, plate: [P], badge: [P], spikes: [[P]], eye: Eye, fang: [P],
                mutter: [P], jaw: [P], shark: [P], teeth: [[P]], arm: Arm, hair: [Shard]) {
        self.version = version; self.name = name; self.box = box; self.plate = plate; self.badge = badge
        self.spikes = spikes; self.eye = eye; self.fang = fang; self.mutter = mutter; self.jaw = jaw
        self.shark = shark; self.teeth = teeth; self.arm = arm; self.hair = hair
    }

    public var size: CGSize { CGSize(width: box.count > 0 ? box[0] : 120, height: box.count > 1 ? box[1] : 60) }

    // MARK: загрузка

    /// Риг из JSON; битый или неполный — nil (тогда фолбэк).
    public static func decode(_ data: Data) -> CapriRig? {
        guard let rig = try? JSONDecoder().decode(CapriRig.self, from: data), rig.problems.isEmpty else { return nil }
        return rig
    }

    public static func load(_ url: URL) -> CapriRig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Что не так с данными (пусто — годится).
    public var problems: [String] {
        var out: [String] = []
        func poly(_ name: String, _ p: [P], min n: Int = 3) {
            if p.count < n { out.append("\(name): меньше \(n) точек") }
            if p.contains(where: { $0.count != 2 || !$0.allSatisfy(\.isFinite) }) { out.append("\(name): точка не x,y") }
        }
        if box.count != 2 || box.contains(where: { $0 <= 0 }) { out.append("box") }
        poly("plate", plate)
        poly("badge", badge)
        if badge.count != plate.count { out.append("badge: число точек не как у plate") }
        for (i, s) in spikes.enumerated() { poly("spikes[\(i)]", s) }
        poly("eye.shape", eye.shape)
        if let t = eye.tick { poly("eye.tick", t) }
        poly("eye.center", [eye.center], min: 1)
        poly("eye.glintAt", [eye.glintAt], min: 1)
        poly("eye.travel", [eye.travel], min: 1)
        if eye.pupil <= 0 || eye.ring < eye.pupil { out.append("eye: радиусы") }
        poly("fang", fang)
        poly("mutter", mutter, min: 2)
        poly("jaw", jaw)
        poly("shark", shark)
        if teeth.isEmpty { out.append("teeth: пусто") }
        for (i, s) in teeth.enumerated() { poly("teeth[\(i)]", s) }
        poly("arm.shoulder", [arm.shoulder], min: 1)
        if arm.upper <= 0 || arm.fore <= 0 || arm.width <= 0 || arm.fingers < 1 { out.append("arm: длины") }
        for (i, s) in hair.enumerated() {
            poly("hair[\(i)]", s.points)
            poly("hair[\(i)].pivot", [s.pivot], min: 1)
        }
        return out
    }

    // MARK: фолбэк

    /// Простая маска без рисунка сериала: трапеция, круглые глаза, треугольный клык, прямые руки, несколько
    /// клиньев позади. Все слои есть — позы работают одинаково с любым рисунком.
    public static let fallback: CapriRig = {
        func circle(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, n: Int = 10) -> [P] {
            (0..<n).map { k in
                let a = Double(k) / Double(n) * 2 * .pi
                return [cx + rx * cos(a), cy + ry * sin(a)]
            }
        }
        return CapriRig(
            name: "fallback",
            box: [120, 60],
            plate: [[10, 8], [60, 6], [110, 8], [102, 46], [60, 48], [18, 46]],
            badge: [[30, 12], [60, 10], [90, 12], [86, 44], [60, 46], [34, 44]],
            spikes: [[[50, 6], [60, 14], [70, 6]]],
            eye: Eye(shape: circle(38, 26, 15, 11), tick: nil, center: [38, 26], pupil: 6.5, ring: 8.5, glint: 2.2,
                     glintAt: [-1.2, -1.2], travel: [5, 3]),
            fang: [[55, 47], [65, 47], [60, 57]],
            mutter: [[44, 52], [50, 49], [56, 53], [62, 49], [68, 53], [74, 49], [78, 52]],
            jaw: [[28, 36], [92, 36], [86, 56], [60, 60], [34, 56]],
            shark: [[30, 36], [90, 36], [80, 54], [40, 54]],
            teeth: [[[34, 36], [42, 36], [38, 44]], [[46, 36], [54, 36], [50, 44]], [[58, 36], [66, 36], [62, 44]],
                    [[70, 36], [78, 36], [74, 44]], [[44, 54], [52, 54], [48, 47]], [[56, 54], [64, 54], [60, 47]],
                    [[68, 54], [76, 54], [72, 47]]],
            arm: Arm(shoulder: [16, 30], upper: 24, fore: 21, width: 5, finger: 10, fingers: 5),
            hair: [Shard(points: [[30, 10], [10, -14], [44, 4]], pivot: [36, 8]),
                   Shard(points: [[56, 8], [60, -22], [70, 8]], pivot: [62, 8]),
                   Shard(points: [[78, 6], [108, -12], [92, 10]], pivot: [84, 8])])
    }()

    // MARK: сборка позы

    /// Фигуры позы сзади вперёд: волосы, руки, пластина, зубцы, рот, глаза, «z». Призрак — растр из этих фигур.
    public func compose(_ pose: RigPose) -> [RigShape] {
        var shapes: [RigShape] = []
        let mid = size.width / 2
        if pose.hair > 0.01 { shapes += hairShapes(pose) }
        shapes += armShapes(pose, side: -1)
        shapes += armShapes(pose, side: 1)
        let b = CGFloat(max(0, min(1, pose.badge)))
        let platePts = zip(plate, badge).map { a, c in
            CGPoint(x: a[0] + (c[0] - a[0]) * Double(b), y: a[1] + (c[1] - a[1]) * Double(b))
        }
        shapes.append(RigShape("plate", .mask, platePts))
        for (i, s) in spikes.enumerated() {
            shapes.append(RigShape("spike\(i)", .ink, scaled(s.map(Self.pt), by: 1 - 0.25 * b, about: CGPoint(x: mid, y: 28))))
        }
        if b < 0.5 { shapes += mouthShapes(pose) }
        shapes += eyeShapes(pose, side: -1)
        shapes += eyeShapes(pose, side: 1)
        if pose.swarm > 0.01 { shapes += swarmShapes(pose) }
        if pose.sleep > 0.01 { shapes += zShapes(pose) }
        // Поворот ¾, дрожь.
        let turned = shapes.map { s -> RigShape in
            var o = s
            o.points = s.points.map { turn($0, pose.turn, hair: s.layer.hasPrefix("hair")) }
            o.points = o.points.map { CGPoint(x: $0.x + pose.shake.dx, y: $0.y + pose.shake.dy) }
            return o
        }
        if pose.ghost > 0.001 { return ghost(turned, pose) }
        return turned
    }

    static func pt(_ p: P) -> CGPoint { CGPoint(x: p[0], y: p[1]) }

    /// Глаз: внешний угол у левого — слева. `side` −1 левый, +1 правый (зеркало).
    func mirror(_ p: CGPoint, _ side: Int) -> CGPoint { side < 0 ? p : CGPoint(x: size.width - p.x, y: p.y) }

    func scaled(_ ps: [CGPoint], by k: CGFloat, about c: CGPoint) -> [CGPoint] {
        ps.map { CGPoint(x: c.x + ($0.x - c.x) * k, y: c.y + ($0.y - c.y) * k) }
    }

    /// Поворот ¾: дальняя половина сжимается сильнее ближней, всё чуть уезжает в сторону взгляда. Волосы — меньше.
    func turn(_ p: CGPoint, _ t: Double, hair: Bool) -> CGPoint {
        guard abs(t) > 0.001 else { return p }
        let mid = size.width / 2
        let k = CGFloat(t) * (hair ? 0.5 : 1)
        let far = (p.x - mid) * k > 0
        let s = 1 - abs(k) * (far ? 0.38 : 0.06)
        return CGPoint(x: mid + (p.x - mid) * s + 10 * k, y: p.y + (far ? -1.5 : 1) * abs(k) * (p.y - 30) * 0.06)
    }

    // MARK: глаза

    func eyeShapes(_ pose: RigPose, side: Int) -> [RigShape] {
        let tag = side < 0 ? "L" : "R"
        let b = CGFloat(max(0, min(1, pose.badge)))
        let c0 = mirror(Self.pt(eye.center), side)
        // В «значке» глаза ближе к середине и мельче; «широкие» — крупнее.
        let center = CGPoint(x: size.width / 2 + (c0.x - size.width / 2) * (1 - 0.3 * b), y: c0.y)
        let k = (1 - 0.25 * b) * (pose.wide > 0 ? 1 + 0.18 * CGFloat(pose.wide) : 1)
        func place(_ p: P) -> CGPoint {
            let m = mirror(Self.pt(p), side)
            return CGPoint(x: center.x + (m.x - c0.x) * k, y: center.y + (m.y - c0.y) * k)
        }
        let almond = eye.shape.map(place)
        var out: [RigShape] = []
        if let t = eye.tick, pose.eyes != .squint, pose.eyes != .happy { out.append(RigShape("eye\(tag).tick", .ink, t.map(place))) }
        switch pose.eyes {
        case .squint:
            out.append(RigShape("eye\(tag).squint", .ink, chevron(almond, pointing: side < 0 ? 1 : -1)))
            return out
        case .happy:
            out.append(RigShape("eye\(tag).happy", .ink, arch(almond)))
            return out
        default: break
        }
        let lid = pose.lid
        let box = RigGeometry.bounds(almond)
        let lidY = box.minY + CGFloat(lid) * box.height
        // Веко: всё выше наклонной линии срезано (у внешнего угла ниже — скучающий взгляд).
        let tilt: CGFloat = 0.14 * CGFloat(-side)
        func cut(_ poly: [CGPoint]) -> [CGPoint] {
            guard lid > 0.001 else { return poly }
            return RigGeometry.clip(poly, keepBelow: { x in lidY + tilt * (x - box.midX) })
        }
        let shell = cut(almond)
        guard shell.count >= 3 else { return out }
        out.append(RigShape("eye\(tag).shell", .ink, shell))
        // Щёлки и закрытые — без зрачка.
        guard lid < 0.72 else { return out }
        let travel = CGSize(width: eye.travel[0] * Double(k), height: eye.travel[1] * Double(k))
        let pc = CGPoint(x: center.x + CGFloat(pose.gaze.dx) * travel.width, y: center.y + CGFloat(pose.gaze.dy) * travel.height)
        let wideK = 1 - 0.25 * CGFloat(pose.wide)
        let ring = RigGeometry.circle(pc, r: CGFloat(eye.ring) * k, n: 20)
        let gap = RigGeometry.circle(pc, r: CGFloat((eye.ring + eye.pupil) / 2) * k, n: 20)
        let pupil = RigGeometry.circle(pc, r: CGFloat(eye.pupil) * k * wideK, n: 18)
        // Блик — то же смещение у обоих глаз (свет с одной стороны).
        let g = CGPoint(x: eye.glintAt[0], y: eye.glintAt[1])
        let glint = RigGeometry.circle(CGPoint(x: pc.x + g.x * k, y: pc.y + g.y * k), r: CGFloat(eye.glint) * k * (pose.wide > 0 ? 1.6 : 1), n: 10)
        for (name, ink, poly) in [("ring", RigInk.ring, ring), ("gap", .ink, gap), ("pupil", .pupil, pupil), ("glint", .glint, glint)] {
            let p = cut(RigGeometry.clip(poly, convex: almond))
            if p.count >= 3 { out.append(RigShape("eye\(tag).\(name)", ink, p)) }
        }
        return out
    }

    /// `><`: толстая галочка остриём к переносице (`pointing` +1 — вправо).
    func chevron(_ almond: [CGPoint], pointing: CGFloat) -> [CGPoint] {
        let b = RigGeometry.bounds(almond)
        let w = b.width * 0.8, h = b.height * 0.95, th = max(2.5, b.height * 0.22)
        let tipX = b.midX + pointing * w / 2, backX = b.midX - pointing * w / 2
        let cy = b.midY
        return [CGPoint(x: backX, y: cy - h / 2), CGPoint(x: tipX, y: cy), CGPoint(x: backX, y: cy + h / 2),
                CGPoint(x: backX + pointing * th * 0.9, y: cy + h / 2 - th * 0.2), CGPoint(x: tipX - pointing * th * 1.4, y: cy),
                CGPoint(x: backX + pointing * th * 0.9, y: cy - h / 2 + th * 0.2)]
    }

    /// `^^`: толстая дуга-домик.
    func arch(_ almond: [CGPoint]) -> [CGPoint] {
        let b = RigGeometry.bounds(almond)
        let w = b.width * 0.82, th = max(2.5, b.height * 0.24)
        let base = b.midY + b.height * 0.2, top = b.midY - b.height * 0.32
        return [CGPoint(x: b.midX - w / 2, y: base), CGPoint(x: b.midX, y: top), CGPoint(x: b.midX + w / 2, y: base),
                CGPoint(x: b.midX + w / 2 - th, y: base + th * 0.15), CGPoint(x: b.midX, y: top + th * 1.15),
                CGPoint(x: b.midX - w / 2 + th, y: base + th * 0.15)]
    }

    /// Перегрузка: рой маленьких глаз по пластине (место и число — от зерна, растут с `swarm`).
    func swarmShapes(_ pose: RigPose) -> [RigShape] {
        let n = Int((14 * pose.swarm).rounded())
        let plateBox = RigGeometry.bounds(plate.map(Self.pt))
        var out: [RigShape] = []
        for k in 0..<n {
            let u = TickNoise.unit(k, 4100 + pose.seed), v = TickNoise.unit(k, 4200 + pose.seed)
            let s = 0.28 + 0.22 * TickNoise.unit(k, 4300 + pose.seed)
            let c = CGPoint(x: plateBox.minX + 8 + (plateBox.width - 16) * u, y: plateBox.minY - 4 + (plateBox.height + 8) * v)
            let c0 = Self.pt(eye.center)
            let shell = eye.shape.map { p in CGPoint(x: c.x + (p[0] - c0.x) * s, y: c.y + (p[1] - c0.y) * s) }
            out.append(RigShape("swarm\(k).shell", .ink, shell))
            let jig = CGFloat(TickNoise.unit(k &+ pose.tick &* 31, 4400) - 0.5) * 3
            out.append(RigShape("swarm\(k).ring", .ring, RigGeometry.circle(CGPoint(x: c.x + jig, y: c.y), r: CGFloat(eye.ring * s), n: 10)))
            out.append(RigShape("swarm\(k).pupil", .pupil, RigGeometry.circle(CGPoint(x: c.x + jig, y: c.y), r: CGFloat(eye.pupil * s * 0.8), n: 10)))
        }
        return out
    }

    // MARK: рот

    func mouthShapes(_ pose: RigPose) -> [RigShape] {
        switch pose.mouth {
        case .none: return []
        case .fang: return [RigShape("mouth.fang", .white, fang.map(Self.pt))]
        case .mutter: return [RigShape("mouth.mutter", .white, RigGeometry.strip(mutter.map(Self.pt), width: 1.8))]
        case .jaw:
            return [RigShape("mouth.jawRim", .mask, scaled(jaw.map(Self.pt), by: 1.08, about: RigGeometry.centroid(jaw.map(Self.pt)))),
                    RigShape("mouth.jaw", .white, jaw.map(Self.pt))]
        case .shark:
            return [RigShape("mouth.shark", .ink, shark.map(Self.pt))]
                + teeth.enumerated().map { i, t in RigShape("mouth.tooth\(i)", .white, t.map(Self.pt)) }
        }
    }

    // MARK: руки

    /// Рука: плечо → локоть → запястье толстой ломаной, пальцы-шипы веером. Растёт из-за пластины (`grow`).
    func armShapes(_ pose: RigPose, side: Int) -> [RigShape] {
        let a = side < 0 ? pose.left : pose.right
        guard a.grow > 0.02 else { return [] }
        let tag = side < 0 ? "L" : "R"
        let s = mirror(Self.pt(arm.shoulder), side)
        let out = CGFloat(side)   // наружу: левая — влево
        func dir(_ deg: Double) -> CGVector {
            let r = deg * .pi / 180
            return CGVector(dx: out * CGFloat(cos(r)), dy: CGFloat(sin(r)))
        }
        let g = CGFloat(a.grow)
        let d1 = dir(a.upper), d2 = dir(a.fore)
        let e = CGPoint(x: s.x + d1.dx * CGFloat(arm.upper) * g, y: s.y + d1.dy * CGFloat(arm.upper) * g)
        let w = CGPoint(x: e.x + d2.dx * CGFloat(arm.fore) * g, y: e.y + d2.dy * CGFloat(arm.fore) * g)
        var shapes = [RigShape("arm\(tag)", .mask, RigGeometry.strip([s, e, w], width: CGFloat(arm.width) * (0.6 + 0.4 * g)))]
        // Кисть: ладонь-ромбик и пальцы-шипы.
        let palm = CGFloat(arm.width) * 1.35 * g
        shapes.append(RigShape("hand\(tag)", .mask, [CGPoint(x: w.x - palm, y: w.y), CGPoint(x: w.x, y: w.y - palm),
                                                     CGPoint(x: w.x + palm, y: w.y), CGPoint(x: w.x, y: w.y + palm)]))
        let n = max(1, arm.fingers)
        for f in 0..<n {
            let k = n == 1 ? 0 : Double(f) / Double(n - 1) - 0.5
            let fd = dir(a.fore + k * a.spread)
            let len = CGFloat(arm.finger) * g * (f == 0 || f == n - 1 ? 0.8 : 1)
            let tip = CGPoint(x: w.x + fd.dx * len, y: w.y + fd.dy * len)
            let nrm = CGVector(dx: -fd.dy, dy: fd.dx)
            let base = CGFloat(arm.width) * 0.32 * g
            shapes.append(RigShape("finger\(tag)\(f)", .mask, [CGPoint(x: w.x + nrm.dx * base, y: w.y + nrm.dy * base), tip,
                                                               CGPoint(x: w.x - nrm.dx * base, y: w.y - nrm.dy * base)]))
        }
        return shapes
    }

    // MARK: волосы

    /// Осколки волос позади маски: фиолетовая кромка со сдвигом, малиновая заливка, блёстки (меняются с `tick`).
    func hairShapes(_ pose: RigPose) -> [RigShape] {
        let h = CGFloat(pose.hair)
        let anchor = CGPoint(x: size.width / 2, y: 26)
        var out: [RigShape] = []
        var sparkles: [RigShape] = []
        for (i, s) in hair.enumerated() {
            let pivot = Self.pt(s.pivot)
            let sway = 0.06 * sin(Double(pose.tick) * 0.9 + Double(i) * 1.7) * pose.sway
            let pts = s.points.map { p -> CGPoint in
                let q = RigGeometry.rotate(Self.pt(p), about: pivot, by: sway)
                return CGPoint(x: anchor.x + (q.x - anchor.x) * h, y: anchor.y + (q.y - anchor.y) * h)
            }
            out.append(RigShape("hair\(i).rim", .rim, pts.map { CGPoint(x: $0.x + 1.6, y: $0.y + 1.1) }))
            out.append(RigShape("hair\(i)", .hair, pts))
            let b = RigGeometry.bounds(pts)
            var k = 0, tries = 0
            let want = max(1, Int(b.width * b.height / 70))
            while k < want, tries < want * 4 {
                tries += 1
                let x = b.minX + b.width * CGFloat(TickNoise.unit(tries &+ pose.tick &* 977, 5000 + i))
                let y = b.minY + b.height * CGFloat(TickNoise.unit(tries &+ pose.tick &* 977, 5100 + i))
                let p = CGPoint(x: x, y: y)
                guard RigGeometry.contains(pts, p) else { continue }
                k += 1
                let r: CGFloat = TickNoise.unit(tries, 5200 + i) < 0.3 ? 0.9 : 0.55
                sparkles.append(RigShape("hair\(i).sparkle", TickNoise.unit(tries &+ pose.tick, 5300) < 0.45 ? .glint : .sparkle,
                                         [CGPoint(x: x - r, y: y), CGPoint(x: x, y: y - r), CGPoint(x: x + r, y: y), CGPoint(x: x, y: y + r)]))
            }
        }
        return out + sparkles
    }

    // MARK: сон

    /// «z» зигзагами вверх-вправо от маски: всплывают и тают (`sleep` 0…1 — сколько их и как высоко).
    func zShapes(_ pose: RigPose) -> [RigShape] {
        var out: [RigShape] = []
        let n = 3
        for k in 0..<n {
            let phase = (Double(pose.tick) / 24 + Double(k) / Double(n)).truncatingRemainder(dividingBy: 1)
            guard Double(k) < pose.sleep * Double(n) + 0.01 else { continue }
            // Справа от маски, всплывают вверх-вправо и растут; тёмная подложка — читается и на волосах.
            let s = CGFloat(3.5 + 4 * phase)
            let x = size.width + 2 + CGFloat(phase) * 16
            let y = size.height * 0.45 - CGFloat(phase) * 34
            let z = [CGPoint(x: x - s, y: y - s), CGPoint(x: x + s, y: y - s), CGPoint(x: x - s, y: y + s), CGPoint(x: x + s, y: y + s)]
            let a = 1 - phase * 0.7
            out.append(RigShape("z\(k).shade", .ink, RigGeometry.strip(z.map { CGPoint(x: $0.x + 0.9, y: $0.y + 0.9) }, width: 2.4), opacity: a))
            out.append(RigShape("z\(k)", .mask, RigGeometry.strip(z, width: 1.8), opacity: a))
        }
        return out
    }

    // MARK: пиксельный призрак

    /// Растр из готовых фигур клетками `cell`: зелёное → серое, чёрное → тёмное, синее и малиновое → красное, белое →
    /// белое; строки сдвинуты (по `tick`), клетки выпадают с ростом `ghost`; поверх — белые вертикальные полосы.
    func ghost(_ shapes: [RigShape], _ pose: RigPose) -> [RigShape] {
        let cell: CGFloat = 3
        let all = shapes.reduce(CGRect.null) { $0.union($1.bounds) }
        guard !all.isNull else { return [] }
        var out: [RigShape] = []
        let cols = Int((all.width / cell).rounded(.up)), rows = Int((all.height / cell).rounded(.up))
        let drop = max(0, (pose.ghost - 0.35) / 0.65)
        for r in 0..<rows {
            let shift = CGFloat((TickNoise.unit(r &+ pose.tick &* 13, 6000 + pose.seed) - 0.5) * 6 * pose.ghost).rounded()
            for c in 0..<cols {
                let p = CGPoint(x: all.minX + (CGFloat(c) + 0.5) * cell, y: all.minY + (CGFloat(r) + 0.5) * cell)
                guard let top = shapes.last(where: { $0.opacity > 0.3 && RigGeometry.contains($0.points, p) }) else { continue }
                if TickNoise.unit(r * 977 + c, 6100 + pose.seed) < drop { continue }
                let ink: RigInk
                switch top.ink {
                case .mask, .ring: ink = .ghostLight
                case .ink, .rim: ink = .ghostDark
                case .white, .glint: ink = .glint
                default: ink = .ghostRed
                }
                let x = all.minX + CGFloat(c) * cell + shift, y = all.minY + CGFloat(r) * cell
                out.append(RigShape("ghost", ink, [CGPoint(x: x, y: y), CGPoint(x: x + cell - 0.4, y: y),
                                                   CGPoint(x: x + cell - 0.4, y: y + cell - 0.4), CGPoint(x: x, y: y + cell - 0.4)]))
            }
        }
        // Белые вертикальные полосы по силуэту.
        for k in 0..<3 {
            let x = all.minX + all.width * CGFloat(TickNoise.unit(k &+ pose.tick &* 7, 6200 + pose.seed))
            let w: CGFloat = 1 + CGFloat(k % 2)
            out.append(RigShape("ghost.stripe", .stripe, [CGPoint(x: x, y: all.minY - 6), CGPoint(x: x + w, y: all.minY - 6),
                                                          CGPoint(x: x + w, y: all.maxY + 6), CGPoint(x: x, y: all.maxY + 6)],
                                opacity: 0.85 * (1 - drop * 0.6)))
        }
        return out
    }
}

/// Геометрия рига: окружности многоугольником, отсечение, полоса из ломаной, попадание точки.
public enum RigGeometry {
    public static func bounds(_ ps: [CGPoint]) -> CGRect {
        guard let f = ps.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for p in ps.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    public static func centroid(_ ps: [CGPoint]) -> CGPoint {
        guard !ps.isEmpty else { return .zero }
        return CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
    }

    public static func circle(_ c: CGPoint, r: CGFloat, n: Int) -> [CGPoint] {
        (0..<n).map { k in
            let a = CGFloat(k) / CGFloat(n) * 2 * .pi
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
    }

    public static func rotate(_ p: CGPoint, about c: CGPoint, by a: Double) -> CGPoint {
        let s = CGFloat(sin(a)), co = CGFloat(cos(a))
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * co - dy * s, y: c.y + dx * s + dy * co)
    }

    /// Оставить часть многоугольника ниже линии `y = line(x)` (y вниз — «ниже» значит больше y).
    public static func clip(_ poly: [CGPoint], keepBelow line: (CGFloat) -> CGFloat) -> [CGPoint] {
        clipEdge(poly, inside: { $0.y >= line($0.x) }, cross: { a, b in lineCross(a, b, line) })
    }

    static func lineCross(_ a: CGPoint, _ b: CGPoint, _ line: (CGFloat) -> CGFloat) -> CGPoint {
        // Линия прямая: y = k·x + m.
        let m0 = line(0), k = line(1) - m0
        let dx = b.x - a.x, dy = b.y - a.y
        let den = dy - k * dx
        guard abs(den) > 1e-9 else { return a }
        let t = (k * a.x + m0 - a.y) / den
        return CGPoint(x: a.x + dx * t, y: a.y + dy * t)
    }

    /// Отсечь многоугольник выпуклым (Сазерленд — Ходжмен). Порядок обхода `convex` любой.
    public static func clip(_ poly: [CGPoint], convex: [CGPoint]) -> [CGPoint] {
        guard convex.count >= 3 else { return poly }
        let orient: CGFloat = area(convex) >= 0 ? 1 : -1
        var out = poly
        for i in convex.indices {
            let a = convex[i], b = convex[(i + 1) % convex.count]
            func side(_ p: CGPoint) -> CGFloat { ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) * orient }
            out = clipEdge(out, inside: { side($0) >= 0 }, cross: { p, q in
                let sp = side(p), sq = side(q)
                let t = sp / (sp - sq)
                return CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
            })
            if out.isEmpty { break }
        }
        return out
    }

    static func clipEdge(_ poly: [CGPoint], inside: (CGPoint) -> Bool, cross: (CGPoint, CGPoint) -> CGPoint) -> [CGPoint] {
        guard !poly.isEmpty else { return [] }
        var out: [CGPoint] = []
        for i in poly.indices {
            let cur = poly[i], prev = poly[(i + poly.count - 1) % poly.count]
            let ci = inside(cur), pi = inside(prev)
            if ci {
                if !pi { out.append(cross(prev, cur)) }
                out.append(cur)
            } else if pi {
                out.append(cross(prev, cur))
            }
        }
        return out
    }

    /// Ориентированная площадь (знак — направление обхода).
    public static func area(_ ps: [CGPoint]) -> CGFloat {
        guard ps.count >= 3 else { return 0 }
        var s: CGFloat = 0
        for i in ps.indices {
            let a = ps[i], b = ps[(i + 1) % ps.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    /// Точка внутри многоугольника (чёт-нечет).
    public static func contains(_ ps: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = ps.count - 1
        for i in ps.indices {
            let a = ps[i], b = ps[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Толстая ломаная одним многоугольником (контур туда по одной стороне, обратно по другой; стыки — среднее
    /// нормалей, с ограничением выноса).
    public static func strip(_ ps: [CGPoint], width: CGFloat) -> [CGPoint] {
        guard ps.count >= 2 else { return ps }
        let h = width / 2
        var left: [CGPoint] = [], right: [CGPoint] = []
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGVector {
            let dx = b.x - a.x, dy = b.y - a.y
            let l = max(1e-6, hypot(dx, dy))
            return CGVector(dx: -dy / l, dy: dx / l)
        }
        for i in ps.indices {
            var n: CGVector
            if i == 0 { n = normal(ps[0], ps[1]) } else if i == ps.count - 1 { n = normal(ps[i - 1], ps[i]) } else {
                let a = normal(ps[i - 1], ps[i]), b = normal(ps[i], ps[i + 1])
                n = CGVector(dx: a.dx + b.dx, dy: a.dy + b.dy)
                let l = max(1e-6, hypot(n.dx, n.dy))
                let cosHalf = max(0.35, (a.dx * b.dx + a.dy * b.dy + 1) / 2)
                let k = 1 / sqrt(cosHalf)
                n = CGVector(dx: n.dx / l * k, dy: n.dy / l * k)
            }
            left.append(CGPoint(x: ps[i].x + n.dx * h, y: ps[i].y + n.dy * h))
            right.append(CGPoint(x: ps[i].x - n.dx * h, y: ps[i].y - n.dy * h))
        }
        return left + right.reversed()
    }
}
