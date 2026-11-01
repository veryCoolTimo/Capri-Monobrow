import Foundation
import CoreGraphics

/// Что вокруг позы на листе и в сцене: пол, верхний край окна, рама с подоконником, дверной проём, терминал.
public enum BodyStage: String, CaseIterable {
    case ground, edge, sill, door, terminal
}

public struct BodyFrame {
    /// Где ноль сцены в клетке листа: по центру на полу, на крае (сидит), сверху (висит), левее (идёт, уползает).
    public enum Spot: Equatable { case floor, seat, hang, walk, leave }

    public var name: String
    public var pose: BodyPose
    public var stage: BodyStage
    public var spot: Spot

    public init(_ name: String, _ pose: BodyPose, _ stage: BodyStage, spot: Spot = .floor) {
        self.name = name; self.pose = pose; self.stage = stage; self.spot = spot
    }
}

/// Позы и анимации тела — чистые функции времени. Ноль сцены у каждой: пол / край окна — `y = 0`, точка опоры —
/// `x = 0` (сиденье, рука на краю, середина стойки). Рост берётся из костей рига.
public enum BodyMoves {
    public typealias Bones = BodyRig.Bones

    /// Талия над полом, когда стоит прямо на кончиках стоп.
    public static func standY(_ b: Bones) -> Double { -(b.hip[1] + b.thigh + b.shin + b.foot) }

    /// Подоконник для позы «оперлась на раму» (точка ладони).
    public static let sill = CGPoint(x: 42, y: -66)

    /// Период качания ног сидя (с).
    public static let swingPeriod = 1.5

    /// Моргание: короткий импульс раз в ~3,7 с.
    public static func blink(_ t: Double, seed: Int = 0) -> Double {
        let period = 3.7 + 0.6 * TickNoise.unit(seed, 8100)
        let x = (t + 1.3 * Double(seed % 7)).truncatingRemainder(dividingBy: period)
        return x < 0.14 ? sin(x / 0.14 * .pi) : 0
    }

    static func breath(_ t: Double) -> Double { sin(t * 2 * .pi / 3.4) }

    static func frac(_ x: Double) -> Double { x - floor(x) }

    // MARK: стоит

    /// Стоит, дышит, моргает, чуть переносит вес.
    public static func idle(_ t: Double, _ b: Bones, seed: Int = 0) -> BodyPose {
        var p = BodyPose()
        let br = breath(t)
        let shift = sin(t * 0.5)
        p.waist = CGPoint(x: 1.5 * shift, y: standY(b) + 1.2 + 0.3 * br)
        p.chest = -90 - 1.5 * shift
        p.pelvis = 92 + 3 * shift
        p.breath = br
        p.neck = 3
        p.head = 5 + 2 * sin(t * 0.37)
        p.footAt = [CGPoint(x: -4, y: -b.foot), CGPoint(x: 5, y: -b.foot)]
        p.kneeBend = [1, -1]
        p.legs[0].end = 93; p.legs[1].end = 87
        p.arms = [BodyLimb(98 + 2 * br, 94, 92, spread: 24), BodyLimb(82 - 2 * br, 86, 120, spread: 40)]
        // Правая ладонь на бедре, локоть наружу — «модельная» стойка.
        p.handAt[1] = CGPoint(x: p.waist.x + 8.5, y: p.waist.y + 3 + 0.3 * br)
        p.elbowBend[1] = -1
        p.face.blink = blink(t, seed: seed)
        p.face.gaze = CGVector(dx: 0.2 * sin(t * 0.3), dy: 0.2)
        p.t = t
        return p
    }

    /// Силуэт в дверном проёме: анфас, ноги вместе, руки чуть в стороны, контровой свет, парит над полом.
    public static func doorway(_ t: Double, _ b: Bones) -> BodyPose {
        var p = BodyPose()
        let br = breath(t)
        p.waist = CGPoint(x: 0, y: standY(b) - 3 + 1.2 * sin(t * 1.3))
        p.breath = br
        p.footAt = [CGPoint(x: -2.2, y: -b.foot - 3 + 1.2 * sin(t * 1.3)), CGPoint(x: 2.2, y: -b.foot - 3 + 1.2 * sin(t * 1.3))]
        p.kneeBend = [-1, 1]
        p.legs[0].end = 88; p.legs[1].end = 92
        p.arms = [BodyLimb(104, 98, 96, spread: 34), BodyLimb(76, 82, 84, spread: 34)]
        p.face = RigPose(eyes: .open, mouth: .none)
        p.backlit = 1
        p.sway = 0.5
        p.t = t
        return p
    }

    /// Оперлась на раму окна (как в сериале): тянется длинной рукой к подоконнику справа, бедро влево,
    /// нога за ногу, ладонь на бедре, голова набок, ехидный взгляд.
    public static func lean(_ t: Double, _ b: Bones) -> BodyPose {
        var p = BodyPose()
        let br = breath(t)
        p.waist = CGPoint(x: -1, y: standY(b) + 4 + 0.3 * br)
        p.chest = -76 + 1.2 * br
        p.pelvis = 104
        p.neck = 8
        p.head = 14
        p.breath = br
        p.handAt = [CGPoint(x: -9, y: p.waist.y + 4), sill]
        p.elbowBend = [1, -1]
        p.arms[0].end = 70; p.arms[0].spread = 40
        p.arms[1].end = 18 + 3 * br; p.arms[1].spread = 70
        p.footAt = [CGPoint(x: -17, y: -b.foot * 0.95), CGPoint(x: -5, y: -b.foot * 0.98)]
        p.kneeBend = [1, -1]
        p.legs[0].end = 100; p.legs[1].end = 82
        p.near = 1
        p.hairTilt = -22
        p.face = RigPose(eyes: .half, mouth: .fang)
        p.face.gaze = CGVector(dx: -0.6, dy: 0.5)
        p.face.turn = -0.25
        p.face.blink = blink(t, seed: 3)
        p.t = t
        return p
    }

    // MARK: край окна

    /// Сидит на верхнем крае окна в ¾ вправо: бёдра лежат на крае, голени свисают и болтаются по очереди,
    /// дальняя рука упёрта в край позади, ближняя — в край перед бедром.
    public static func sit(_ t: Double, _ b: Bones, swing: Double = 1) -> BodyPose {
        var p = BodyPose()
        let br = breath(t)
        let ph = t * 2 * .pi / swingPeriod
        p.chest = -98 + 1.5 * br
        p.pelvis = 70
        p.neck = 6
        p.head = 8 + 3 * sin(t * 0.8)
        p.breath = br
        // Дальнее бедро (0) — короче и выше ближнего (¾), не сливается с ним; голени болтаются широко.
        p.legs = [0, 1].map { i in
            let s = sin(ph + Double(i) * .pi) * swing
            let shin = 92 + (i == 0 ? 6 : -8) + 40 * s
            return BodyLimb(i == 0 ? -4 : 6, shin, shin - 14 - 16 * s, reach: i == 0 ? 0.62 : 0.82)
        }
        p.handAt = [CGPoint(x: -13, y: -1.8), CGPoint(x: 10, y: -1.8)]
        p.elbowBend = [1, 1]
        p.arms[0].end = 160; p.arms[1].end = 15
        p.arms[0].spread = 40; p.arms[1].spread = 50
        p.pin = .seat
        p.pinAt = CGPoint(x: 0, y: 0.5)
        p.near = 1
        p.face = RigPose(eyes: .open, mouth: .fang)
        p.face.turn = 0.35
        p.face.gaze = CGVector(dx: 0.5 + 0.3 * sin(t * 0.4), dy: 0.5)
        p.face.blink = blink(t, seed: 1)
        p.t = t
        return p
    }

    /// Висит на краю на одной руке, раскачивается маятником, свободная рука болтается.
    public static func hang(_ t: Double, _ b: Bones) -> BodyPose {
        var p = BodyPose()
        let th = 7 * sin(t * 1.9)
        p.chest = -94 + th
        p.pelvis = 88 + th
        p.neck = -14
        p.head = -14
        p.arms[1] = BodyLimb(-90 + th * 0.4, -90 + th * 0.4, -95, spread: 30)
        p.arms[0] = BodyLimb(118 + th, 104 + th + 12 * sin(t * 2.6), 100 + th, spread: 50)
        p.legs = [BodyLimb(94 + th, 98 + th, 96 + th), BodyLimb(84 + th, 64 + th, 72 + th)]
        p.pin = .wrist(1)
        p.pinAt = CGPoint(x: 0, y: b.hand + 1)
        p.face = RigPose(eyes: .half, mouth: .mutter)
        p.face.gaze = CGVector(dx: -0.3, dy: 0.8)
        p.lift = -0.4
        p.hairTilt = -38 - th
        p.t = t
        return p
    }

    /// Сидит на верхнем крае терминала, наклонилась вперёд и тычет пальцем вниз, в экран; говорит.
    public static func terminal(_ t: Double, _ b: Bones) -> BodyPose {
        var p = sit(t * 0.5, b, swing: 0.35)
        let jab = max(0, sin(t * 5)) * 6
        p.chest = -72
        p.neck = 12
        p.head = 16
        p.handAt[1] = nil
        p.arms[1] = BodyLimb(38 - jab * 0.5, 62 - jab, 66 - jab, spread: 5)
        p.handAt[0] = CGPoint(x: -14, y: -1.8)
        p.face = RigPose(eyes: .open, mouth: Int(t * 6) % 3 == 0 ? .mutter : .fang)
        p.face.gaze = CGVector(dx: 0.5, dy: 1)
        p.face.turn = 0.3
        p.t = t
        return p
    }

    /// Шагает вправо по краю на цыпочках-шипах: `phase` — циклы шага (один цикл — два шага).
    public static func walk(_ phase: Double, _ b: Bones, stride: Double = 20) -> BodyPose {
        var p = BodyPose()
        let x0 = 2 * stride * phase
        p.waist = CGPoint(x: x0, y: standY(b) + 2.5 + 1.4 * cos(4 * .pi * phase))
        // Корпус наклонён вперёд ~15°, руки машут шире — шаг читается и в анфас-риге.
        p.chest = -76
        p.pelvis = 84
        p.neck = -4
        p.head = -3
        var feet: [CGPoint?] = [nil, nil]
        for i in 0..<2 {
            let q = frac(phase + 0.5 * Double(i))
            let rel: Double, lift: Double
            if q < 0.5 {
                rel = stride / 2 - q / 0.5 * stride
                lift = 0
            } else {
                let u = (q - 0.5) / 0.5
                rel = -stride / 2 + stride * BodyIK.smooth(u)
                lift = 6 * sin(.pi * u)
            }
            feet[i] = CGPoint(x: x0 + rel, y: -b.foot * 0.9 - lift)
            p.legs[i].end = q < 0.5 ? 80 : 66
            let swing = 50 * sin(2 * .pi * phase + Double(i) * .pi) * -1
            p.arms[i] = BodyLimb(90 + swing + (i == 0 ? 14 : -14), 90 + swing - 30, 90 + swing - 36, spread: 30)
        }
        p.footAt = feet
        p.kneeBend = [-1, -1]
        p.near = 1
        p.face = RigPose(eyes: .open, mouth: .fang)
        p.face.turn = 0.5
        p.face.gaze = CGVector(dx: 1, dy: 0.1)
        p.t = phase * 1.2
        return p
    }

    /// Растекается лужей и уползает: `k` 0…1 — стекает, 1…2 — лужа уползает вправо.
    public static func melt(_ k: Double, _ b: Bones, t: Double = 0) -> BodyPose {
        var p = idle(t, b)
        p.melt = k
        p.ground = 0
        p.face = RigPose(eyes: k < 0.35 ? .open : .slit, mouth: k < 0.5 ? .jaw : .none)
        p.face.wide = k < 0.35 ? 1 : 0
        p.lift = -k
        p.t = t
        return p
    }

    // MARK: танец

    /// Танец под бит: `beat` — доли (дробные), качание бёдрами на каждую долю, приседание на долю, руки по
    /// тактам (одна машет, другая на бедре; потом обе вверх «V»), волосы подлетают от приседа.
    public static func dance(_ beat: Double, _ b: Bones) -> BodyPose {
        var p = BodyPose()
        let ph = frac(beat)
        let hit = 0.5 + 0.5 * cos(2 * .pi * ph)
        let side = sin(.pi * beat)
        // Узкая стойка: опорная нога почти прямая, другая согнута, бедро выведено в сторону опорной. Глубокий
        // присед — только на сильную долю такта, на остальных — лёгкий пружинящий.
        let down = Int(floor(beat)) % 4 == 0
        let squat = (down ? 6.5 : 2) * hit
        p.waist = CGPoint(x: 5 * side, y: standY(b) + 1.5 + squat)
        p.chest = -90 - 7 * side
        p.pelvis = 90 + 14 * side
        p.neck = 5 * sin(2 * .pi * beat)
        p.head = 10 * side
        let support = side >= 0 ? 1 : 0
        // Опорная — наружу на кончике; свободная — ближе, на полупальцах (колено сгибается само).
        p.footAt = support == 1
            ? [CGPoint(x: -4, y: -b.foot * 1.6), CGPoint(x: 7, y: -b.foot * 0.95)]
            : [CGPoint(x: -7, y: -b.foot * 0.95), CGPoint(x: 4, y: -b.foot * 1.6)]
        p.kneeBend = [1, -1]
        p.legs[0].end = support == 0 ? 96 : 76; p.legs[1].end = support == 1 ? 84 : 104
        let bar = Int(floor(beat / 4)) % 2
        let pump = cos(2 * .pi * ph)
        if bar == 0 {
            p.arms[1] = BodyLimb(-35 + 12 * sin(2 * .pi * beat), -80 + 30 * sin(2 * .pi * beat), -95, spread: 75)
            p.handAt[0] = CGPoint(x: p.waist.x - 9, y: p.waist.y + 2)
            p.elbowBend[0] = 1
            p.arms[0].end = 60
            p.face = RigPose(eyes: .happy, mouth: Int(floor(beat)) % 2 == 0 ? .jaw : .fang)
        } else {
            p.arms[0] = BodyLimb(-150 - 8 * pump, -115 - 16 * pump, -110, spread: 70)
            p.arms[1] = BodyLimb(-30 + 8 * pump, -65 + 16 * pump, -70, spread: 70)
            p.face = RigPose(eyes: .squint, mouth: .shark)
        }
        p.lift = 0.9 * pump
        p.t = beat * 0.6
        return p
    }

    // MARK: лист

    /// Все позы для листа одобрения.
    public static func catalog(_ b: Bones) -> [BodyFrame] {
        [
            BodyFrame("idle", idle(1.0, b), .ground),
            BodyFrame("idle blink", { var p = idle(1.0, b); p.face.blink = 1; return p }(), .ground),
            BodyFrame("sit on edge", sit(0.2, b), .edge, spot: .seat),
            BodyFrame("lean on frame", lean(0.5, b), .sill),
            BodyFrame("doorway", doorway(0.4, b), .door),
            BodyFrame("dance", dance(0.1, b), .ground),
            BodyFrame("dance V", dance(4.1, b), .ground),
            BodyFrame("hang", hang(0.6, b), .edge, spot: .hang),
            BodyFrame("terminal point", terminal(0.3, b), .terminal, spot: .seat),
            BodyFrame("walk", walk(0.15, b), .edge, spot: .walk),
            BodyFrame("walk 2", walk(0.4, b), .edge, spot: .walk),
            BodyFrame("melt .4", melt(0.4, b), .ground),
            BodyFrame("melt .8", melt(0.8, b), .ground),
            BodyFrame("puddle", melt(1.0, b), .ground),
            BodyFrame("leaving", melt(1.5, b), .ground, spot: .leave),
        ]
    }

    /// Кадры полосы: танец (две доли по четверти — в каждом такте) и качание ног сидя (один период).
    public static func danceStrip(_ b: Bones, frames: Int = 8) -> [BodyFrame] {
        (0..<frames).map { k in
            let beat = Double(k) * 0.25 + (k >= frames / 2 ? 3 : 0)
            return BodyFrame(String(format: "beat %.2f", beat), dance(beat, b), .ground)
        }
    }

    public static func swingStrip(_ b: Bones, frames: Int = 8) -> [BodyFrame] {
        (0..<frames).map { k in
            let t = swingPeriod * Double(k) / Double(frames)
            return BodyFrame(String(format: "t %.2f", t), sit(t, b), .edge, spot: .seat)
        }
    }
}
