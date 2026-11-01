import Foundation
import CoreGraphics

/// Capri в полный рост: 2D-скелет (грудь, таз, шея, голова, руки и ноги по три звена) и плоские многоугольники
/// без обводки на костях, масса волос-осколков, лицо — маска мини-рига (`CapriRig`) на голове.
///
/// Части рисуются в «стоячей» системе кости: (x, y) с y вниз, начало — в начале кости, кость в покое направлена
/// как `rest` (грудь, шея, голова — вверх; таз и все звенья конечностей — вниз). Конечности нарисованы для
/// левой на экране стороны (x < 0 — наружу), правая — зеркало. Волосы и голова — от основания головы.
///
/// В репозитории — простой фолбэк (`fallback`, своя геометрия). Подробный рисунок «по мотивам» — локально в
/// `~/.capri/art/capri-body.json` (грузит `load(_:)`).
public struct BodyRig: Codable, Equatable {
    public typealias P = [Double]

    public struct Bones: Codable, Equatable {
        public var chest, pelvis, neck, head: Double
        public var upperArm, foreArm, hand, finger: Double
        public var thigh, shin, foot: Double
        /// Левое плечо — от талии в системе груди; левое бедро — от талии в системе таза.
        public var shoulder: P
        public var hip: P
        /// Низ таза (сиденье) — в системе таза.
        public var seat: P
        public var fingers: Int
        public var fingerWidth: Double
    }

    public enum Bone: String, Codable, CaseIterable {
        case chest, pelvis, neck, head, upperArm, foreArm, hand, thigh, shin, foot

        /// Направление кости в покое (градусы экрана).
        public var rest: Double {
            switch self {
            case .chest, .neck, .head: -90
            default: 90
            }
        }

        public var isLimb: Bool { ![.chest, .pelvis, .neck, .head].contains(self) }
        public var isArm: Bool { [.upperArm, .foreArm, .hand].contains(self) }
    }

    public struct Part: Codable, Equatable {
        public var bone: Bone
        public var ink: RigInk
        public var points: [P]
    }

    public struct Shard: Codable, Equatable {
        public var points: [P]
        /// Точка качания (от основания головы).
        public var pivot: P
        /// Перед лицом (иначе — за головой).
        public var front: Bool?
    }

    public var version: Int
    public var name: String
    public var bones: Bones
    public var parts: [Part]
    public var hair: [Shard]
    /// Ширина маски-лица и её центр (от основания головы, в стоячей системе головы).
    public var face: P

    public init(version: Int = 1, name: String, bones: Bones, parts: [Part], hair: [Shard], face: P) {
        self.version = version; self.name = name; self.bones = bones; self.parts = parts; self.hair = hair; self.face = face
    }

    // MARK: загрузка

    public static func decode(_ data: Data) -> BodyRig? {
        guard let rig = try? JSONDecoder().decode(BodyRig.self, from: data), rig.problems.isEmpty else { return nil }
        return rig
    }

    public static func load(_ url: URL) -> BodyRig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    public var problems: [String] {
        var out: [String] = []
        let b = bones
        let lens = [b.chest, b.pelvis, b.neck, b.head, b.upperArm, b.foreArm, b.hand, b.finger, b.thigh, b.shin, b.foot]
        if lens.contains(where: { !($0 > 0) || !$0.isFinite }) { out.append("bones: длины") }
        for (n, p) in [("shoulder", b.shoulder), ("hip", b.hip), ("seat", b.seat), ("face", face)] where p.count != 2 || !p.allSatisfy(\.isFinite) {
            out.append("\(n): не x,y")
        }
        if b.fingers < 1 || b.fingers > 8 { out.append("fingers") }
        if parts.isEmpty { out.append("parts: пусто") }
        for (i, p) in parts.enumerated() where p.points.count < 3 || p.points.contains(where: { $0.count != 2 || !$0.allSatisfy(\.isFinite) }) {
            out.append("parts[\(i)]")
        }
        for (i, s) in hair.enumerated() where s.points.count < 3 || s.pivot.count != 2 || !s.pivot.allSatisfy(\.isFinite)
            || s.points.contains(where: { $0.count != 2 || !$0.allSatisfy(\.isFinite) }) {
            out.append("hair[\(i)]")
        }
        return out
    }

    /// Рост от макушки (без волос) до кончика стопы, если стоять прямо.
    public var height: Double {
        let b = bones
        return b.chest + b.neck + b.head + b.hip[1] + b.thigh + b.shin + b.foot
    }

    // MARK: скелет

    public func skeleton(_ pose: BodyPose) -> BodySkeleton {
        let pose = pose.normalized
        var s = solve(pose)
        // Пришпилено: сдвигаем талию и решаем ещё раз, чтобы цели IK остались в координатах сцены.
        if let j = pose.pin {
            let p = s.point(j)
            var q = pose
            q.waist = CGPoint(x: pose.waist.x + pose.pinAt.x - p.x, y: pose.waist.y + pose.pinAt.y - p.y)
            s = solve(q)
            let p2 = s.point(j)
            s.shift(CGVector(dx: pose.pinAt.x - p2.x, dy: pose.pinAt.y - p2.y))
        }
        return s
    }

    func solve(_ pose: BodyPose) -> BodySkeleton {
        let b = bones
        let w = pose.waist
        func local(_ origin: CGPoint, _ angle: Double, _ rest: Double, _ p: P, mirror: Double = 1) -> CGPoint {
            let r = (angle - rest) * .pi / 180
            let x = p[0] * mirror, y = p[1]
            return CGPoint(x: origin.x + CGFloat(x * cos(r) - y * sin(r)), y: origin.y + CGFloat(x * sin(r) + y * cos(r)))
        }
        let breath = pose.breath
        let neckBase = BodyIK.step(w, pose.chest, b.chest + 0.4 * breath)
        let neckA = pose.chest + pose.neck
        let headBase = BodyIK.step(neckBase, neckA, b.neck)
        let headA = neckA + pose.head
        let shoulderP: P = [b.shoulder[0], b.shoulder[1] - 0.6 * breath]
        let shoulders: [CGPoint] = [local(w, pose.chest, -90, shoulderP), local(w, pose.chest, -90, shoulderP, mirror: -1)]
        let hips: [CGPoint] = [local(w, pose.pelvis, 90, b.hip), local(w, pose.pelvis, 90, b.hip, mirror: -1)]
        let seat = local(w, pose.pelvis, 90, b.seat)
        var arms = pose.arms, legs = pose.legs
        var elbows: [CGPoint] = [], wrists: [CGPoint] = [], handEnds: [CGPoint] = []
        var knees: [CGPoint] = [], ankles: [CGPoint] = [], toes: [CGPoint] = []
        for i in 0..<2 {
            if let t = pose.handAt[i] {
                let (a1, a2) = BodyIK.solve(root: shoulders[i], target: t, l1: b.upperArm * arms[i].reach, l2: b.foreArm, bend: pose.elbowBend[i])
                arms[i].upper = a1; arms[i].lower = a2
            }
            let e = BodyIK.step(shoulders[i], arms[i].upper, b.upperArm * arms[i].reach)
            let wr = BodyIK.step(e, arms[i].lower, b.foreArm)
            elbows.append(e); wrists.append(wr)
            handEnds.append(BodyIK.step(BodyIK.step(wr, arms[i].end, b.hand), arms[i].end, b.finger))
            if let t = pose.footAt[i] {
                let (a1, a2) = BodyIK.solve(root: hips[i], target: t, l1: b.thigh * legs[i].reach, l2: b.shin, bend: pose.kneeBend[i])
                legs[i].upper = a1; legs[i].lower = a2
            }
            let k = BodyIK.step(hips[i], legs[i].upper, b.thigh * legs[i].reach)
            let an = BodyIK.step(k, legs[i].lower, b.shin)
            knees.append(k); ankles.append(an); toes.append(BodyIK.step(an, legs[i].end, b.foot))
        }
        return BodySkeleton(waist: w, chest: pose.chest, pelvis: pose.pelvis, neck: neckA, head: headA,
                             neckBase: neckBase, headBase: headBase, shoulders: shoulders, elbows: elbows, wrists: wrists,
                             handEnds: handEnds, hips: hips, knees: knees, ankles: ankles, toes: toes, arms: arms, legs: legs,
                             seat: seat)
    }

    // MARK: сборка

    /// Фигуры позы сзади вперёд: волосы сзади, дальние рука и нога, ближняя нога, таз, грудь, шея, голова, лицо,
    /// ближняя рука, передние пряди; у малиновых частей — фиолетовая кромка-копия; блёстки поверх.
    /// `sparkle` — плотность блёсток 0…1 (мелкий масштаб — меньше, под пиксель их не видно).
    public func compose(_ pose: BodyPose, face mask: CapriRig = .fallback, sparkle: Double = 1) -> [RigShape] {
        let pose = pose.normalized
        let sk = skeleton(pose)
        let b = bones
        func place(_ origin: CGPoint, _ angle: Double, _ rest: Double, _ pts: [P], mirror: Double = 1, sx: Double = 1) -> [CGPoint] {
            let r = (angle - rest) * .pi / 180
            let c = cos(r), s = sin(r)
            return pts.map { p in
                let x = p[0] * mirror, y = p[1] * sx
                return CGPoint(x: origin.x + CGFloat(x * c - y * s), y: origin.y + CGFloat(x * s + y * c))
            }
        }
        var layers: [RigShape] = []
        let far = pose.near > 0 ? 0 : 1, nearI = 1 - far
        let backlit = pose.backlit
        func ink(_ i: RigInk, deep: Bool) -> RigInk {
            if backlit > 0.5, i == .hair { return .deep }
            return deep && i == .hair ? .deep : i
        }
        // Кромка тела — одним слоем за всем телом (`rims`): фиолетовый сдвиг виден только по внешнему краю силуэта,
        // а не вокруг каждой детали (иначе тонкие руки и ноги выглядят обведённой проволокой).
        var rims: [RigShape] = []
        func add(_ name: String, _ i: RigInk, _ pts: [CGPoint], deep: Bool = false) {
            guard pts.count >= 3 else { return }
            let k = ink(i, deep: deep)
            if k == .hair || k == .deep {
                rims.append(RigShape(name + ".rim", backlit > 0.5 ? .light : .rim,
                                     pts.map { CGPoint(x: $0.x + pose.rim.dx, y: $0.y + pose.rim.dy) }))
                if backlit > 0.5 {
                    rims.append(RigShape(name + ".rim2", .light, pts.map { CGPoint(x: $0.x - pose.rim.dx, y: $0.y + pose.rim.dy) }))
                }
            }
            layers.append(RigShape(name, k, pts))
        }
        func parts(_ bone: Bone, origin: CGPoint, angle: Double, side: Int? = nil, deep: Bool = false, sx: Double = 1) {
            let m: Double = side == 1 ? -1 : 1
            for (j, p) in self.parts.enumerated() where p.bone == bone {
                add("\(bone.rawValue)\(side.map { $0 == 0 ? "L" : "R" } ?? "")#\(j)", p.ink,
                    place(origin, angle, bone.rest, p.points, mirror: m, sx: sx), deep: deep)
            }
        }
        // Волосы: от основания головы, качаются вокруг своих точек; `lift` < 0 — повисают (кончики к низу),
        // > 0 — подлетают. Кромка — одной группой (только по внешнему краю массы), потом заливки.
        func hairShards(front: Bool) {
            var fills: [(String, [CGPoint])] = []
            for (i, s) in hair.enumerated() where (s.front ?? false) == front {
                let sway = (0.05 * sin(pose.t * 1.6 + Double(i) * 1.37) + 0.02 * sin(pose.t * 3.1 + Double(i))) * pose.sway
                let px = s.pivot[0] * pose.hair, py = s.pivot[1] * pose.hair
                var pts: [P] = s.points.map { [$0[0] * pose.hair, $0[1] * pose.hair] }
                let cx = pts.map { $0[0] }.reduce(0, +) / Double(pts.count), cy = pts.map { $0[1] }.reduce(0, +) / Double(pts.count)
                let phi = atan2(cy - py, cx - px) * 180 / .pi + sk.head + 90
                var rot = sway
                if pose.lift > 0 { rot += BodyIK.delta(phi, -90) * pose.lift * 0.12 * .pi / 180 }
                // Подброс тянет массу вверх, «повисли» — сплющивает к голове.
                let stretch = 1 + 0.12 * pose.lift
                pts = pts.map { p in
                    let dx = p[0] - px, dy = (p[1] - py) * stretch
                    return [px + dx * cos(rot) - dy * sin(rot), py + dx * sin(rot) + dy * cos(rot)]
                }
                // Вся масса целиком наклоняется вокруг основания головы (висит, падает).
                fills.append(("hair\(i)", place(sk.headBase, sk.head + pose.hairTilt, -90, pts)))
            }
            let rimInk: RigInk = backlit > 0.5 ? .light : .rim
            for (n, pts) in fills {
                layers.append(RigShape(n + ".rim", rimInk, pts.map { CGPoint(x: $0.x + pose.rim.dx * 1.4, y: $0.y + pose.rim.dy * 1.4) }))
                if backlit > 0.5 {
                    layers.append(RigShape(n + ".rim2", rimInk, pts.map { CGPoint(x: $0.x - pose.rim.dx * 1.4, y: $0.y + pose.rim.dy) }))
                }
            }
            for (n, pts) in fills { layers.append(RigShape(n, backlit > 0.5 ? .deep : .hair, pts)) }
        }
        // Руки поверх волос: чернильный контур ~1.5 ед. со всех сторон (как в сериале — пересечения через чёрное).
        func outlined(_ body: () -> Void) {
            let from = layers.count
            body()
            let added = layers[from...].filter { $0.ink == .hair || $0.ink == .deep }
            var outline: [RigShape] = []
            for sh in added {
                for (dx, dy) in [(-1.5, 0.0), (1.5, 0), (0, -1.5), (0, 1.5), (-1.1, -1.1), (1.1, -1.1), (-1.1, 1.1), (1.1, 1.1)] {
                    outline.append(RigShape(sh.layer + ".outline", .ink, sh.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }))
                }
            }
            layers.insert(contentsOf: outline, at: from)
        }
        func arm(_ i: Int, deep: Bool) {
            let a = sk.arms[i]
            parts(.upperArm, origin: sk.shoulders[i], angle: a.upper, side: i, deep: deep, sx: a.reach)
            parts(.foreArm, origin: sk.elbows[i], angle: a.lower, side: i, deep: deep)
            parts(.hand, origin: sk.wrists[i], angle: a.end, side: i, deep: deep)
            // Пальцы-шипы веером от конца ладони.
            let palm = BodyIK.step(sk.wrists[i], a.end, b.hand * 0.8)
            let n = max(1, b.fingers)
            for f in 0..<n {
                let k = n == 1 ? 0 : Double(f) / Double(n - 1) - 0.5
                let ang = a.end + k * a.spread * (i == 0 ? 1 : -1)
                let len = b.finger * (f == 0 ? 0.62 : (f == n - 1 ? 0.8 : 1))
                let base = BodyIK.step(palm, ang, -0.5)
                let tip = BodyIK.step(palm, ang, len)
                let nrm = BodyIK.dir(ang + 90)
                let w = CGFloat(b.fingerWidth / 2)
                add("finger\(i)\(f)", .hair, [CGPoint(x: base.x + nrm.dx * w, y: base.y + nrm.dy * w), tip,
                                              CGPoint(x: base.x - nrm.dx * w, y: base.y - nrm.dy * w)], deep: deep)
            }
        }
        func leg(_ i: Int, deep: Bool) {
            let l = sk.legs[i]
            parts(.foot, origin: sk.ankles[i], angle: l.end, side: i, deep: deep)
            parts(.shin, origin: sk.knees[i], angle: l.lower, side: i, deep: deep)
            parts(.thigh, origin: sk.hips[i], angle: l.upper, side: i, deep: deep, sx: l.reach)
        }
        hairShards(front: false)
        let bodyStart = layers.count
        outlined { arm(far, deep: true) }
        leg(far, deep: true)
        leg(nearI, deep: false)
        parts(.pelvis, origin: sk.waist, angle: sk.pelvis)
        parts(.chest, origin: sk.waist, angle: sk.chest)
        parts(.neck, origin: sk.neckBase, angle: sk.neck)
        parts(.head, origin: sk.headBase, angle: sk.head)
        // Лицо: маска мини-рига, ширина `face[0]`, центр `face[1]` над основанием головы.
        var fp = pose.face
        fp.hair = 0
        fp.left = .hidden; fp.right = .hidden
        fp.tick = pose.tick
        let fs = face[0] / Double(mask.size.width)
        let mh = Double(mask.size.height)
        for sh in mask.compose(fp) {
            let pts: [P] = sh.points.map { [(Double($0.x) - Double(mask.size.width) / 2) * fs, (Double($0.y) - mh / 2) * fs + face[1]] }
            var o = RigShape("face." + sh.layer, sh.ink, place(sk.headBase, sk.head, -90, pts), opacity: sh.opacity)
            if backlit > 0.5 { o.opacity *= 0.55 }
            layers.append(o)
        }
        outlined { arm(nearI, deep: false) }
        hairShards(front: true)

        // Контровой свет: осколки парят у ног (как в дверном проёме в сериале).
        if backlit > 0.5 {
            let fx = (sk.toes[0].x + sk.toes[1].x) / 2, fy = max(sk.toes[0].y, sk.toes[1].y)
            for (j, d) in [(-15.0, -6.0, 13.0, 3.2), (14.0, -10.0, 16.0, 3.6), (-9.0, 4.0, 9.0, 2.6), (21.0, 2.0, 8.0, 2.4)].enumerated() {
                let bob = CGFloat(sin(pose.t * 1.7 + Double(j)))
                let c = CGPoint(x: fx + CGFloat(d.0), y: fy + CGFloat(d.1) + bob)
                let tilt = CGFloat((j % 2 == 0 ? -1 : 1) * 0.25)
                let h = CGFloat(d.2), w = CGFloat(d.3)
                add("shard\(j)", .hair, [CGPoint(x: c.x - w / 2, y: c.y + h * 0.4), CGPoint(x: c.x + tilt * h, y: c.y - h * 0.6),
                                         CGPoint(x: c.x + w / 2, y: c.y + h * 0.4), CGPoint(x: c.x, y: c.y + h * 0.55)])
            }
        }
        layers.insert(contentsOf: rims, at: bodyStart)
        if pose.melt > 0.001 { layers = melted(layers, pose, sk) }
        if pose.flip {
            let cx = sk.waist.x
            layers = layers.map { s in var o = s; o.points = s.points.map { CGPoint(x: 2 * cx - $0.x, y: $0.y) }; return o }
        }
        return layers + sparkles(layers, pose, density: sparkle)
    }

    // MARK: блёстки

    /// Белые и розовые точки на малиновом, каждый кадр (`tick`) — другие.
    /// Всего не больше `maxSparkles` за кадр (каждая — заливка на Canvas).
    public static let maxSparkles = 450

    func sparkles(_ shapes: [RigShape], _ pose: BodyPose, density: Double = 1) -> [RigShape] {
        var out: [RigShape] = []
        let dim = pose.backlit > 0.5
        let dens = max(0, min(1, density))
        guard dens > 0.01 else { return [] }
        let red = shapes.enumerated().filter { $0.element.ink == .hair || $0.element.ink == .deep }
        // Сколько хочется по площади — и общий потолок: густо, но не тысяча заливок за кадр.
        func want(_ s: RigShape) -> Double {
            let area = abs(Double(RigGeometry.area(s.points)))
            return area / (dim ? 60 : (s.layer.hasPrefix("hair") ? 9 : 16)) * dens
        }
        let total = red.reduce(0) { $0 + want($1.element) }
        let cap = total > Double(Self.maxSparkles) ? Double(Self.maxSparkles) / total : 1
        for (i, s) in red {
            let b = s.bounds
            let want = Int(want(s) * cap)
            guard want > 0 else { continue }
            var k = 0, tries = 0
            while k < want, tries < want * 4 {
                tries += 1
                let x = b.minX + b.width * CGFloat(TickNoise.unit(tries &+ pose.tick &* 977, 7000 + i))
                let y = b.minY + b.height * CGFloat(TickNoise.unit(tries &+ pose.tick &* 977, 7100 + i))
                let p = CGPoint(x: x, y: y)
                guard RigGeometry.contains(s.points, p) else { continue }
                k += 1
                // Реже — значит крупнее (на 1× мелкие уходят под пиксель).
                let r: CGFloat = (TickNoise.unit(tries, 7200 + i) < 0.2 ? 0.5 : 0.28) * CGFloat(1 + 0.8 * (1 - dens))
                let glint = TickNoise.unit(tries &+ pose.tick, 7300 + i) < 0.4
                out.append(RigShape("sparkle", glint ? .glint : .sparkle,
                                    [CGPoint(x: x - r, y: y), CGPoint(x: x, y: y - r), CGPoint(x: x + r, y: y), CGPoint(x: x, y: y + r)],
                                    opacity: (dim ? 0.5 : 1) * s.opacity))
            }
        }
        return out
    }

    // MARK: клякса

    /// Тело стекает к `ground` и расплывается вширь, лицо съезжает в лужу; 1…2 — лужа уползает и тает.
    func melted(_ shapes: [RigShape], _ pose: BodyPose, _ sk: BodySkeleton) -> [RigShape] {
        let k = BodyIK.smooth(min(1, pose.melt))
        let leave = max(0, min(1, pose.melt - 1))
        let gy = CGFloat(pose.ground)
        let cx = sk.waist.x
        let top = shapes.reduce(CGFloat.infinity) { min($0, $1.bounds.minY) }
        let h = max(1, gy - top)
        let dir = CGFloat(pose.leaveDir >= 0 ? 1 : -1)
        let slide = CGFloat(BodyIK.smooth(leave)) * 70 * dir
        let shrink = CGFloat(1 - leave)
        func m(_ p: CGPoint, _ i: Int) -> CGPoint {
            // Тонет в лужу: всё опускается к полу (верх чуть сплющивается), а что ушло бы под пол — растекается
            // вширь по полу. Ноги первыми «вливаются» в лужу, тело не сжимается целиком.
            let drop = CGFloat(k) * h * 0.97
            let sinkY = gy - (gy - p.y) * (1 - CGFloat(k) * 0.3) + drop * 0.72
            let over = max(0, sinkY - gy)
            let side: CGFloat = p.x == cx ? (i % 2 == 0 ? 1 : -1) : (p.x > cx ? 1 : -1)
            let wob = CGFloat(sin(Double(i) * 0.7 + pose.t * 4)) * CGFloat(k) * 1.2
            let spread = 40 * (1 - CGFloat(exp(-Double(over) / 24)))
            let x = cx + (p.x - cx) * (1 + CGFloat(k) * 0.25) + side * spread + wob
            let y = min(gy - 0.4 * CGFloat(TickNoise.unit(i, 7700)) - (over > 0 ? 0.3 : 0), sinkY)
            return CGPoint(x: cx + (x - cx) * shrink + slide, y: gy - (gy - y) * (0.5 + 0.5 * shrink))
        }
        var out: [RigShape] = []
        // Лужа под всем.
        let pw = CGFloat(10 + 46 * k) * shrink, ph = CGFloat(1.5 + 4.5 * k) * shrink
        if pw > 0.5 {
            let puddle = (0..<14).map { j -> CGPoint in
                let a = Double(j) / 14 * 2 * .pi
                let jag = 1 + 0.16 * (TickNoise.unit(j, 7400) - 0.5)
                return CGPoint(x: cx + slide + pw * CGFloat(cos(a) * jag), y: gy - ph * 0.3 + ph * CGFloat(sin(a) * jag))
            }
            out.append(RigShape("puddle.rim", .rim, puddle.map { CGPoint(x: $0.x - 1, y: $0.y + 0.8) }))
            out.append(RigShape("puddle", .hair, puddle))
        }
        // Брызги: торчащие вверх малиновые осколки и зелёные треугольники маски в луже (как в сериале).
        var splash: [RigShape] = []
        if k > 0.45 {
            let rise = CGFloat(BodyIK.smooth((k - 0.45) / 0.4)) * shrink
            for j in 0..<5 {
                let u = CGFloat(j) / 4 - 0.5
                let x = cx + slide + u * pw * 1.3 + CGFloat(TickNoise.unit(j, 7800) - 0.5) * 6
                let hgt = CGFloat(9 + 15 * TickNoise.unit(j, 7810)) * rise * (1 - abs(u) * 0.8)
                let w = CGFloat(2.4 + 2 * TickNoise.unit(j, 7820)) * shrink
                let lean = (u + CGFloat(TickNoise.unit(j, 7830) - 0.5) * 0.6) * hgt * 0.5
                let base = gy - ph * 0.2
                let pts = [CGPoint(x: x - w, y: base), CGPoint(x: x + lean, y: base - hgt), CGPoint(x: x + w, y: base)]
                splash.append(RigShape("splash\(j).rim", .rim, pts.map { CGPoint(x: $0.x - 0.9, y: $0.y + 0.4) }))
                splash.append(RigShape("splash\(j)", .hair, pts))
            }
            for j in 0..<3 {
                let x = cx + slide + (CGFloat(j) - 1) * pw * 0.42 + 4
                let y = gy - ph * 0.15
                let r = CGFloat(2.6 + 1.2 * TickNoise.unit(j, 7840)) * rise
                let rot = Double(j) * 2.1 + 0.4
                let pts = (0..<3).map { q -> CGPoint in
                    let a = rot + Double(q) * 2 * .pi / 3
                    return CGPoint(x: x + r * CGFloat(cos(a)) * 1.4, y: y + r * CGFloat(sin(a)) * 0.55)
                }
                splash.append(RigShape("splash.mask\(j)", .mask, pts))
            }
        }
        var faceShift = CGVector.zero
        if let eyes = shapes.first(where: { $0.layer.hasPrefix("face.") }) {
            let c = RigGeometry.centroid(eyes.points)
            let target = CGPoint(x: cx + slide + (c.x - cx) * 0.4, y: gy - 4 * shrink)
            faceShift = CGVector(dx: (target.x - c.x) * CGFloat(k), dy: (target.y - c.y) * CGFloat(k))
        }
        for (i, s) in shapes.enumerated() {
            var o = s
            if s.layer.hasPrefix("face.") {
                o.points = s.points.map { CGPoint(x: $0.x + faceShift.dx, y: $0.y + faceShift.dy) }
                o.opacity *= Double(shrink)
            } else if s.layer.hasPrefix("hair") {
                // Волосы сначала стягиваются к голове, потом оседают вместе со всем — колючки в луже.
                let hb = sk.headBase, z = 1 - 0.72 * CGFloat(k)
                o.points = s.points.enumerated().map { m(CGPoint(x: hb.x + ($1.x - hb.x) * z, y: hb.y + ($1.y - hb.y) * z), i * 7 + $0) }
                o.opacity *= Double(max(0, 1 - leave * 1.3))
            } else {
                o.points = s.points.enumerated().map { m($1, i * 7 + $0) }
                o.opacity *= Double(max(0, 1 - leave * 1.3))
            }
            out.append(o)
        }
        out += splash.map { var o = $0; o.opacity *= Double(max(0, 1 - leave * 1.3)); return o }
        // Капли во время стекания.
        if k > 0.1, k < 0.95 {
            for j in 0..<4 {
                let x = cx + CGFloat(TickNoise.unit(j, 7500 + pose.seed) - 0.5) * 40 * CGFloat(k)
                let y = gy - CGFloat(1 - k) * h * CGFloat(0.3 + 0.5 * TickNoise.unit(j, 7600))
                out.append(RigShape("drip\(j)", .hair, [CGPoint(x: x - 1.6, y: y), CGPoint(x: x + 1.6, y: y), CGPoint(x: x, y: y + 6)]))
            }
        }
        return out
    }
}

// MARK: фолбэк

extension BodyRig {
    public static let standardBones = Bones(chest: 28, pelvis: 12, neck: 5, head: 12, upperArm: 24, foreArm: 23, hand: 5, finger: 9,
                                            thigh: 33, shin: 35, foot: 9, shoulder: [-9.5, -25], hip: [-4.5, 6], seat: [0, 12],
                                            fingers: 4, fingerWidth: 1.3)

    /// Простое тело без рисунка сериала: клинья-сегменты, корона из девяти осколков, чёрная голова с рогами.
    public static let fallback: BodyRig = {
        func part(_ b: Bone, _ i: RigInk, _ p: [P]) -> Part { Part(bone: b, ink: i, points: p) }
        func shard(_ p: [P], _ pv: P, front: Bool? = nil) -> Shard { Shard(points: p, pivot: pv, front: front) }
        return BodyRig(
            name: "fallback",
            bones: standardBones,
            parts: [
                part(.chest, .hair, [[-3.2, 0], [-5, -9], [-7.5, -17], [-10.5, -24], [-8, -26.5], [-2.5, -28.5], [2.5, -28.5],
                                     [8, -26.5], [10.5, -24], [7.5, -17], [5, -9], [3.2, 0]]),
                part(.chest, .ink, [[-5, -26.8], [5, -26.8], [0, -17]]),
                part(.chest, .mask, [[1.5, -21], [6.5, -19], [3, -15]]),
                part(.pelvis, .hair, [[-3.4, -1], [3.4, -1], [7, 6], [6, 10], [0, 13], [-6, 10], [-7, 6]]),
                part(.pelvis, .ink, [[-6.2, 6.5], [6.2, 6.5], [0, 13.2]]),
                part(.pelvis, .mask, [[-7.2, 5.5], [-4.5, 7], [-6.8, 10]]),
                part(.pelvis, .mask, [[7.2, 5.5], [4.5, 7], [6.8, 10]]),
                part(.neck, .ink, [[-1.6, 1], [1.6, 1], [1.2, -5.5], [-1.2, -5.5]]),
                part(.head, .ink, [[-8, -1], [8, -1], [9, -8], [7, -14], [3, -11], [0, -15], [-3, -11], [-7, -14], [-9, -8]]),
                part(.upperArm, .hair, [[-2.4, -1.5], [2, -1], [1.5, 24], [-1.6, 24]]),
                part(.foreArm, .hair, [[-1.6, 0], [1.5, 0], [0.9, 23], [-1, 23]]),
                part(.hand, .hair, [[-1.3, 0], [1.2, 0], [1.8, 3], [0, 5], [-1.8, 3]]),
                part(.thigh, .hair, [[-3.6, -1], [3.4, -1], [2, 33], [-2, 33]]),
                part(.shin, .hair, [[-2.1, 0], [2, 0], [2.4, 10], [1, 35], [-1, 35], [-1.8, 12]]),
                part(.foot, .hair, [[-1.1, 0], [1.1, 0], [0, 9.5]]),
            ],
            hair: [
                shard([[-34, -10], [-40, -28], [-30, -44], [-18, -52], [-4, -60], [10, -56], [24, -50], [36, -40], [40, -24],
                       [34, -8], [20, -2], [-20, -2]], [0, -8]),
                shard([[-30, -36], [-52, -50], [-38, -24]], [-30, -30]),
                shard([[-14, -50], [-22, -76], [-2, -56]], [-10, -50]),
                shard([[6, -56], [18, -80], [22, -52]], [10, -54]),
                shard([[28, -44], [54, -54], [36, -28]], [28, -40]),
                shard([[34, -20], [58, -14], [34, -6]], [32, -14]),
                shard([[-34, -20], [-58, -10], [-34, -6]], [-32, -14]),
                shard([[-20, -6], [-28, 30], [-12, -2]], [-16, -4]),
                shard([[18, -6], [30, 26], [12, -2]], [16, -4]),
            ],
            face: [15, -6])
    }()
}
