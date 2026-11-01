import Foundation
import CoreGraphics

/// Рука рига в «своей» системе: 0° — горизонтально наружу, −90° — вверх, 90° — вниз (y вниз). Правая — зеркало.
public struct RigArm: Equatable {
    /// Плечо и предплечье (абсолютные углы), веер пальцев, насколько выросла (0 — спрятана за пластиной).
    public var upper: Double
    public var fore: Double
    public var spread: Double
    public var grow: Double

    public init(upper: Double = 70, fore: Double = 100, spread: Double = 30, grow: Double = 0) {
        self.upper = upper; self.fore = fore; self.spread = spread; self.grow = grow
    }

    public static let hidden = RigArm()

    public static func mix(_ a: RigArm, _ b: RigArm, _ k: Double) -> RigArm {
        RigArm(upper: lerp(a.upper, b.upper, k), fore: lerp(a.fore, b.fore, k), spread: lerp(a.spread, b.spread, k),
               grow: lerp(a.grow, b.grow, k))
    }
}

func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

/// Поза мини-маски: состояние глаз и рта, взгляд, руки, поворот, «значок», волосы, эффекты. Чистые данные —
/// фигуры по ней собирает `CapriRig.compose`.
public struct RigPose: Equatable {
    /// Открыт, полувеко (скука), щёлки, `><` (смех/прищур), `^^` (довольна).
    public enum Eyes: String, CaseIterable { case open, half, slit, squint, happy }
    /// Нет рта, клык, зигзаг-бормотание, челюсть-осколок, акулья ухмылка.
    public enum Mouth: String, CaseIterable { case none, fang, mutter, jaw, shark }
    /// Готовые позы рук.
    public enum Arms: String, CaseIterable { case none, rest, wave, flex, cap, point, grip }

    public var eyes: Eyes = .open
    /// Моргание поверх состояния: 0 — как есть, 1 — закрыты (щель).
    public var blink = 0.0
    /// Куда смотрит: −1…1 по x (вправо +) и y (вниз +).
    public var gaze = CGVector.zero
    /// Распахнутые глаза (удивление, перегрузка): 0…1.
    public var wide = 0.0
    /// Размер зрачка с кольцом: 1 — как нарисовано, больше — «внимательно слушает».
    public var pupil = 1.0
    public var mouth: Mouth = .fang
    public var left = RigArm.hidden
    public var right = RigArm.hidden
    /// Поворот ¾: −1…1 (вправо +).
    public var turn = 0.0
    /// Сжатие в «значок» 0…1 (без рта).
    public var badge = 0.0
    /// Волосы-осколки за маской (0 — нет, 1 — обычные) и их покачивание.
    public var hair = 0.0
    public var sway = 1.0
    /// Рой глаз 0…1, «z» сна 0…1, пиксельный призрак 0…1 (1 — рассыпалась).
    public var swarm = 0.0
    public var sleep = 0.0
    public var ghost = 0.0
    /// Дрожь (в единицах рига).
    public var shake = CGVector.zero
    /// Кадр 12 fps (блёстки, рой, призрак) и зерно сцены.
    public var tick = 0
    public var seed = 0

    public init(eyes: Eyes = .open, mouth: Mouth = .fang) { self.eyes = eyes; self.mouth = mouth }

    /// Насколько срезано веко: состояние + моргание (не больше 0,92 — остаётся щель-линия).
    public var lid: Double {
        let base: Double = switch eyes {
        case .half: 0.45
        case .slit: 0.8
        default: 0
        }
        return base + max(0, min(1, blink)) * (0.92 - base)
    }

    /// Обе руки в позу (`phase` — фаза махания 0…1 и т. п.; `toward` — куда показывать пальцем: −1 влево, +1 вправо).
    public mutating func set(_ a: Arms, phase: Double = 0, grow: Double = 1, toward: Double = 1) {
        let (l, r) = Self.arms(a, phase: phase, toward: toward)
        left = l; right = r
        left.grow *= grow; right.grow *= grow
    }

    public static func arms(_ a: Arms, phase: Double = 0, toward: Double = 1) -> (RigArm, RigArm) {
        let wob = sin(phase * 2 * .pi)
        switch a {
        case .none: return (.hidden, .hidden)
        case .rest:
            let r = RigArm(upper: 75, fore: 110, spread: 30, grow: 0.7)
            return (r, r)
        case .wave:
            // Обе руки вверх-наружу, кисти машут в противофазе.
            return (RigArm(upper: -38, fore: -95 + 30 * wob, spread: 80, grow: 1),
                    RigArm(upper: -38, fore: -95 - 30 * wob, spread: 80, grow: 1))
        case .flex:
            let r = RigArm(upper: 5, fore: -95, spread: 40, grow: 1)
            return (r, r)
        case .cap:
            let r = RigArm(upper: -75, fore: -175, spread: 50, grow: 0.9)
            return (r, r)
        case .point:
            // Одна рука вниз-наружу к цели, пальцы вместе; другая спрятана.
            let p = RigArm(upper: 35, fore: 45, spread: 8, grow: 1)
            return toward < 0 ? (p, .hidden) : (.hidden, p)
        case .grip:
            let r = RigArm(upper: 80, fore: 92, spread: 55, grow: 0.85)
            return (r, r)
        }
    }

    /// Непрерывная смесь поз: числа — линейно, состояния глаз/рта — переключаются на середине.
    public static func mix(_ a: RigPose, _ b: RigPose, _ k: Double) -> RigPose {
        let k = max(0, min(1, k))
        var o = k < 0.5 ? a : b
        // Разные состояния век — через моргание: к середине глаза закрываются, на середине меняются.
        if a.eyes != b.eyes {
            let close = 1 - abs(2 * k - 1)
            o.blink = max(lerp(a.blink, b.blink, k), close)
        } else {
            o.blink = lerp(a.blink, b.blink, k)
        }
        o.gaze = CGVector(dx: lerp(a.gaze.dx, b.gaze.dx, k), dy: lerp(a.gaze.dy, b.gaze.dy, k))
        o.wide = lerp(a.wide, b.wide, k)
        o.pupil = lerp(a.pupil, b.pupil, k)
        o.left = RigArm.mix(a.left, b.left, k)
        o.right = RigArm.mix(a.right, b.right, k)
        o.turn = lerp(a.turn, b.turn, k)
        o.badge = lerp(a.badge, b.badge, k)
        o.hair = lerp(a.hair, b.hair, k)
        o.swarm = lerp(a.swarm, b.swarm, k)
        o.sleep = lerp(a.sleep, b.sleep, k)
        o.ghost = lerp(a.ghost, b.ghost, k)
        o.shake = CGVector(dx: lerp(a.shake.dx, b.shake.dx, k), dy: lerp(a.shake.dy, b.shake.dy, k))
        return o
    }

    /// Именованные выражения и позы — для листа рига и тестов.
    public static let library: [(String, RigPose)] = {
        func p(_ e: Eyes, _ m: Mouth, _ f: (inout RigPose) -> Void = { _ in }) -> RigPose {
            var x = RigPose(eyes: e, mouth: m)
            x.hair = 1
            f(&x)
            return x
        }
        return [
            ("нейтрально", p(.open, .fang)),
            ("говорит", p(.open, .mutter) { $0.gaze = CGVector(dx: 0.6, dy: 0.2) }),
            ("скука", p(.half, .mutter) { $0.gaze = CGVector(dx: -0.8, dy: 0.3) }),
            ("косится", p(.half, .fang) { $0.gaze = CGVector(dx: 1, dy: -0.2) }),
            ("щёлки", p(.slit, .none)),
            ("смех ><", p(.squint, .jaw)),
            ("довольна ^^", p(.happy, .fang)),
            ("удивление", p(.open, .none) { $0.wide = 1 }),
            ("злорадство", p(.half, .shark) { $0.gaze = CGVector(dx: 0.5, dy: 0.6) }),
            ("моргнула", p(.open, .fang) { $0.blink = 1 }),
            ("зевает", p(.slit, .jaw)),
            ("засыпает", p(.half, .mutter) { $0.blink = 0.85; $0.sleep = 1; $0.clockTick(5) }),
            ("машет", p(.happy, .fang) { $0.set(.wave, phase: 0.25) }),
            ("бицепс", p(.open, .shark) { $0.set(.flex) }),
            ("кепка", p(.half, .mutter) { $0.set(.cap) }),
            ("показывает", p(.open, .fang) { $0.set(.point); $0.gaze = CGVector(dx: 0.8, dy: 0.8) }),
            ("держится", p(.open, .fang) { $0.set(.grip); $0.wide = 0.6 }),
            ("¾ вправо", p(.open, .fang) { $0.turn = 1; $0.gaze = CGVector(dx: 1, dy: 0) }),
            ("¾ влево", p(.half, .mutter) { $0.turn = -1; $0.gaze = CGVector(dx: -1, dy: 0) }),
            ("значок", p(.open, .none) { $0.badge = 1; $0.hair = 0 }),
            ("без волос", p(.open, .fang) { $0.hair = 0 }),
            ("перегрузка", p(.open, .shark) { $0.wide = 1; $0.swarm = 1; $0.seed = 7 }),
            ("призрак", p(.open, .fang) { $0.ghost = 0.3; $0.tick = 3 }),
            ("призрак тает", p(.open, .fang) { $0.ghost = 0.8; $0.tick = 9 }),
        ]
    }()

    mutating func clockTick(_ t: Int) { tick = t }
}

/// Моменты на риге по времени сцены: прилёт с маханием, разговор, скука/зевок, моргания, засыпает, злорадство,
/// перегрузка, пиксельный призрак. Чистые функции таймлайна (`t` — время сцены, зерно — из `SceneOptions`).
public enum RigMoments {
    /// Машет `^^` после прилёта на окно.
    public static let waveLen = 1.7
    /// Зевок в скуке.
    public static let yawnLen = 0.9
    /// Засыпает, если столько секунд никто не трогал (терминал), и опускает веки столько секунд.
    public static let sleepAfter = 40.0
    public static let sleepFall = 3.0
    /// Рой глаз перед молнией домой (много сессий ждут сразу).
    public static let overloadLen = 0.5
    /// Пиксельный призрак (хост потерян) — рассыпается за столько секунд.
    public static let ghostLen = 1.4
    /// Волосы у мини-маски (меньше, чем в листе: на чужом окне не должны забивать пузырь и содержимое).
    public static let hair = 0.6

    static func u(_ o: SceneOptions, _ salt: Int) -> Double { TickNoise.unit(o.seed, salt) }

    /// Взгляд на точку (глобально, AppKit: y вверх) от глаз.
    public static func gaze(from eyes: CGRect, to p: CGPoint?) -> CGVector {
        guard let p else { return .zero }
        let dx = max(-1, min(1, (p.x - eyes.midX) / 160))
        let dy = max(-1, min(1, -(p.y - eyes.midY) / 110))
        return CGVector(dx: dx, dy: dy)
    }

    /// Обычная поза на окне (прилёт, уход, прыжок).
    public static func base(_ o: SceneOptions, t: Double) -> RigPose {
        var p = RigPose(eyes: .open, mouth: .fang)
        p.hair = hair
        p.seed = o.seed
        p.tick = Int(t * 12)
        return p
    }

    // MARK: посадка на окно

    public static func yawnAt(_ o: SceneOptions) -> Double { PerchTimeline.speakEnd(o) + 1.6 + 0.8 * u(o, 4501) }

    /// Есть ли зевок в этой посадке (успевает до ухода).
    public static func yawns(_ o: SceneOptions) -> Bool {
        yawnAt(o) + yawnLen < PerchTimeline.duration(o) - PerchTimeline.leaveLen - 0.3
    }

    /// Поза посадки в покое. `look` — сейчас «косится» (доля 0…1), `blink` — моргание (0…1).
    public static func perch(_ t: Double, _ g: SceneGeometry, _ o: SceneOptions, look: Double?, blink: Double?) -> RigPose {
        var p = base(o, t: t)
        let eyes = g.target
        let typedAt = PerchTimeline.typedAt(o), speakEnd = PerchTimeline.speakEnd(o)
        let toBubble = gaze(from: eyes, to: g.bubble.map { CGPoint(x: $0.midX, y: $0.midY) })
        let toCursor = gaze(from: eyes, to: g.cursor)
        if t < speakEnd {
            // Говорит: рот хлопает между клыком и зигзагом, смотрит на пузырь.
            p.gaze = CGVector(dx: toBubble.dx * 0.8, dy: toBubble.dy * 0.6)
            if t >= PerchTimeline.typeStart, t < typedAt { p.mouth = Int(t * 6) % 2 == 0 ? .fang : .mutter }
        } else {
            // Скучает: полувеко, бормочет, косится на курсор.
            p.eyes = .half
            p.mouth = .mutter
            p.gaze = CGVector(dx: toCursor.dx == 0 ? -0.7 : toCursor.dx, dy: max(-0.3, toCursor.dy * 0.5))
            if let l = look {
                // «Косится» в другую сторону и обратно.
                let swing = sin(l * .pi)
                p.gaze.dx = p.gaze.dx * (1 - 2 * swing)
            }
            if yawns(o) {
                let k = t - yawnAt(o)
                if k >= 0, k < yawnLen {
                    p.eyes = .slit
                    p.mouth = k > 0.12 && k < yawnLen - 0.12 ? .jaw : .mutter
                }
            }
        }
        // Прилёт: ^^ и машет обеими руками; руки вырастают и прячутся.
        let w = t - PerchTimeline.arrive
        if w >= 0, w < waveLen {
            let grow = min(1, w / 0.2, (waveLen - w) / 0.25)
            p.set(.wave, phase: w * 2.4, grow: max(0, grow))
            if w < 0.9 { p.eyes = .happy }
        }
        if let b = blink, p.eyes != .happy { p.blink = b }
        if o.perchHold {
            p.set(.grip)
            p.wide = 0.6
            p.eyes = .open
            p.mouth = .fang
        }
        return p
    }

    // MARK: смотрит в терминал

    /// С какого момента засыпает (nil — не успевает). Будит новая реплика.
    public static func sleepStart(_ t: Double, _ w: SceneWatch) -> Double? {
        sleepWindows(w).first { t >= $0.0 && t < $0.1 }?.0
    }

    /// Когда спит: с `sleepAfter` после прилёта и не раньше чем через 6 с после реплики; реплика будит; злорадство,
    /// призрак и уход — конец сна.
    public static func sleepWindows(_ w: SceneWatch) -> [(Double, Double)] {
        var cutoff = WatchTimeline.leaveStart(w)
        if let g = w.gloatAt { cutoff = min(cutoff, g) }
        if let g = w.ghostAt { cutoff = min(cutoff, g) }
        var out: [(Double, Double)] = []
        var start = WatchTimeline.arrive + sleepAfter
        for k in w.says.indices {
            let s = WatchTimeline.span(k, w)
            if s.start > start { out.append((start, min(s.start, cutoff))) }
            start = max(start, s.end + 6)
        }
        if start < cutoff { out.append((start, cutoff)) }
        return out.filter { $0.1 > $0.0 }
    }

    public static func watch(_ t: Double, _ g: SceneGeometry, _ o: SceneOptions, _ w: SceneWatch,
                             look: Double?, blink: Double?, speaking: Int?) -> RigPose {
        var p = base(o, t: t)
        let eyes = g.target
        let into = CGPoint(x: w.window.midX, y: w.window.minY + w.window.height * 0.25)
        let toTerm = gaze(from: eyes, to: into)
        p.gaze = CGVector(dx: toTerm.dx, dy: max(0.4, toTerm.dy))
        if let l = look {
            let swing = sin(l * .pi)
            let cur = gaze(from: eyes, to: g.cursor)
            p.gaze = CGVector(dx: lerp(p.gaze.dx, cur.dx == 0 ? -p.gaze.dx : cur.dx, swing), dy: lerp(p.gaze.dy, cur.dy, swing))
        }
        if let k = speaking {
            let s = WatchTimeline.span(k, w)
            let at = w.says[k].at
            if t >= at, t < s.typed { p.mouth = Int(t * 6) % 2 == 0 ? .fang : .mutter }
            // Показывает пальцем в терминал, пока печатает (и чуть после).
            let pk = t - at
            if pk >= 0, t < s.typed + 0.6 {
                let grow = min(1, pk / 0.2, max(0, (s.typed + 0.6 - t) / 0.25))
                p.set(.point, grow: grow, toward: into.x >= eyes.midX ? 1 : -1)
            }
        }
        if let b = blink { p.blink = b }
        if let s = sleepStart(t, w) {
            let k = min(1, (t - s) / sleepFall)
            p.eyes = .half
            p.blink = max(p.blink, 0.9 * k)
            p.mouth = .mutter
            p.gaze = CGVector(dx: p.gaze.dx * (1 - k), dy: 0.6 * k)
            p.sleep = k
            p.sway = 1 - 0.7 * k
        }
        if let at = w.gloatAt, t >= at {
            let k = t - at
            let tick = Int(k * 12)
            p.blink = 0
            p.set(.none)
            if k < 1.0 {
                // Язвительный смех: `><` + челюсть, сильная тряска.
                p.eyes = .squint
                p.mouth = .jaw
                p.shake = CGVector(dx: (TickNoise.unit(tick, 4601 + o.seed) - 0.5) * 5, dy: (TickNoise.unit(tick, 4602 + o.seed) - 0.5) * 3)
            } else {
                // Злорадство: акулья ухмылка, полувеко, мелкая дрожь, волосы дыбом.
                p.eyes = .half
                p.mouth = .shark
                p.gaze = CGVector(dx: toTerm.dx * 0.6, dy: 0.7)
                p.hair = hair * 1.12
                p.shake = CGVector(dx: (TickNoise.unit(tick, 4603 + o.seed) - 0.5) * 2, dy: (TickNoise.unit(tick, 4604 + o.seed) - 0.5) * 1.2)
            }
        }
        if let at = w.ghostAt, t >= at {
            p.set(.none)
            p.blink = 0
            p.mouth = .fang
            p.ghost = min(1, (t - at) / ghostLen)
        }
        if o.perchHold {
            p.set(.grip)
            p.wide = 0.6
        }
        return p
    }

    // MARK: перегрузка

    /// Рой глаз на месте перед молнией домой: `k` — секунды от обрыва.
    public static func overload(_ k: Double, _ o: SceneOptions) -> RigPose {
        var p = base(o, t: k)
        p.eyes = .open
        p.wide = 1
        p.mouth = .shark
        p.swarm = min(1, k / 0.15)
        p.hair = hair * 1.2
        let tick = Int(k * 24)
        p.tick = tick
        p.shake = CGVector(dx: (TickNoise.unit(tick, 4701 + o.seed) - 0.5) * 6, dy: (TickNoise.unit(tick, 4702 + o.seed) - 0.5) * 4)
        return p
    }
}
