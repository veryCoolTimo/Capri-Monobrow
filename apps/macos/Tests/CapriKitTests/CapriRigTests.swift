import XCTest
import CoreGraphics
@testable import CapriKit

/// Этап 5 плана присутствия: векторная мини-маска (риг) и моменты на ней.
final class CapriRigTests: XCTestCase {
    let rig = CapriRig.fallback
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

    func layers(_ p: RigPose, _ r: CapriRig? = nil) -> [String] { (r ?? rig).compose(p).map(\.layer) }

    // MARK: данные

    func testFallbackIsValidAndRoundTripsThroughJSON() throws {
        XCTAssertEqual(rig.problems, [])
        let data = try JSONEncoder().encode(rig)
        XCTAssertEqual(CapriRig.decode(data), rig)
    }

    func testBrokenJSONFallsBack() throws {
        XCTAssertNil(CapriRig.decode(Data("{".utf8)))
        var bad = rig
        bad.badge.removeLast()
        XCTAssertNil(CapriRig.decode(try JSONEncoder().encode(bad)), "морф пластины требует то же число точек")
        bad = rig
        bad.eye.shape = [[1, 1]]
        XCTAssertFalse(bad.problems.isEmpty)
        XCTAssertNil(CapriRig.load(URL(fileURLWithPath: "/nonexistent/capri-rig.json")))
    }

    // MARK: состояния лица

    func testEveryFaceStateComposes() {
        for e in RigPose.Eyes.allCases {
            for m in RigPose.Mouth.allCases {
                let l = layers(RigPose(eyes: e, mouth: m))
                XCTAssertTrue(l.contains("plate"), "\(e) \(m)")
                XCTAssertTrue(l.contains { $0.hasPrefix("eyeL.") } && l.contains { $0.hasPrefix("eyeR.") }, "\(e) \(m)")
                XCTAssertEqual(l.contains { $0.hasPrefix("mouth.") }, m != .none, "\(e) \(m)")
                // Зрачок — только у открытых и полувека.
                XCTAssertEqual(l.contains("eyeL.pupil"), e == .open || e == .half, "\(e)")
            }
        }
        XCTAssertTrue(layers(RigPose(eyes: .squint, mouth: .jaw)).contains("eyeL.squint"))
        XCTAssertTrue(layers(RigPose(eyes: .happy, mouth: .fang)).contains("eyeR.happy"))
        var closed = RigPose()
        closed.blink = 1
        XCTAssertFalse(layers(closed).contains("eyeL.pupil"), "моргнула — без зрачка")
        XCTAssertTrue(layers(closed).contains("eyeL.shell"), "щель остаётся")
    }

    func testLibraryAndArmsComposeWithBothRigs() throws {
        let art = try XCTUnwrap(CapriRig.decode(try JSONEncoder().encode(rig)))
        for (name, p) in RigPose.library {
            XCTAssertFalse(rig.compose(p).isEmpty, name)
            XCTAssertFalse(art.compose(p).isEmpty, name)
        }
        var w = RigPose()
        w.set(.wave, phase: 0.3)
        XCTAssertTrue(layers(w).contains("armL") && layers(w).contains("armR") && layers(w).contains("fingerR3"))
        var pt = RigPose()
        pt.set(.point, toward: -1)
        XCTAssertTrue(layers(pt).contains("armL"))
        XCTAssertFalse(layers(pt).contains("armR"))
        XCTAssertFalse(layers(RigPose()).contains { $0.hasPrefix("arm") }, "без рук по умолчанию")
        var b = RigPose()
        b.badge = 1
        XCTAssertFalse(layers(b).contains { $0.hasPrefix("mouth.") }, "значок без рта")
    }

    /// Лицо не вылезает за коробку и глаза — за пластину при любом повороте, «значке» и взгляде.
    func testFaceStaysOnPlate() {
        let box = CGRect(origin: .zero, size: rig.size).insetBy(dx: -2, dy: -2)
        for turn in stride(from: -1.0, through: 1.0, by: 0.25) {
            for badge in [0.0, 0.5, 1.0] {
                for gx in [-1.0, 0, 1] {
                    var p = RigPose()
                    p.turn = turn; p.badge = badge; p.gaze = CGVector(dx: gx, dy: gx)
                    let shapes = rig.compose(p)
                    let plate = shapes.first { $0.layer == "plate" }!.bounds.insetBy(dx: -1, dy: -1)
                    XCTAssertTrue(box.contains(plate), "\(turn) \(badge)")
                    for s in shapes where s.layer.hasPrefix("eye") && !s.layer.hasSuffix("tick") {
                        XCTAssertTrue(plate.contains(s.bounds), "\(s.layer) \(turn) \(badge) \(gx)")
                    }
                    // Зрачок — внутри миндаля (обрезан им).
                    for side in ["L", "R"] {
                        let shell = shapes.first { $0.layer == "eye\(side).shell" }!.bounds.insetBy(dx: -0.01, dy: -0.01)
                        let pupil = shapes.first { $0.layer == "eye\(side).pupil" }!.bounds
                        XCTAssertTrue(shell.contains(pupil), "\(side) \(turn) \(gx)")
                    }
                }
            }
        }
    }

    func testPoseMixIsContinuous() {
        var a = RigPose(eyes: .open, mouth: .fang)
        var b = RigPose(eyes: .open, mouth: .fang)
        a.set(.rest); b.set(.wave, phase: 0.25)
        a.gaze = CGVector(dx: -1, dy: 0); b.gaze = CGVector(dx: 1, dy: 0.5)
        b.turn = 1
        func tip(_ p: RigPose) -> CGPoint { rig.compose(p).first { $0.layer == "fingerR1" }!.points[1] }
        func pupil(_ p: RigPose) -> CGPoint { RigGeometry.centroid(rig.compose(p).first { $0.layer == "eyeL.pupil" }!.points) }
        var prev = RigPose.mix(a, b, 0)
        for k in 1...100 {
            let cur = RigPose.mix(a, b, Double(k) / 100)
            XCTAssertLessThan(hypot(tip(cur).x - tip(prev).x, tip(cur).y - tip(prev).y), 2.5, "рука прыгнула на \(k)")
            XCTAssertLessThan(hypot(pupil(cur).x - pupil(prev).x, pupil(cur).y - pupil(prev).y), 1.0, "зрачок прыгнул на \(k)")
            prev = cur
        }
        XCTAssertEqual(RigPose.mix(a, b, 0), a)
        // Смена состояния век — через моргание.
        let m = RigPose.mix(RigPose(eyes: .open), RigPose(eyes: .half), 0.5)
        XCTAssertGreaterThan(m.lid, 0.85)
    }

    func testGeometryHelpers() {
        let sq = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let c = RigGeometry.clip(RigGeometry.circle(CGPoint(x: 10, y: 10), r: 6, n: 16), convex: sq)
        XCTAssertTrue(c.allSatisfy { $0.x >= -1e-6 && $0.x <= 10 + 1e-6 && $0.y >= -1e-6 && $0.y <= 10 + 1e-6 })
        XCTAssertGreaterThan(abs(RigGeometry.area(c)), 20)
        let below = RigGeometry.clip(sq, keepBelow: { _ in 4 })
        XCTAssertEqual(RigGeometry.bounds(below).minY, 4, accuracy: 1e-6)
        XCTAssertTrue(RigGeometry.contains(sq, CGPoint(x: 5, y: 5)))
        XCTAssertFalse(RigGeometry.contains(sq, CGPoint(x: 15, y: 5)))
        XCTAssertEqual(RigGeometry.strip([.zero, CGPoint(x: 10, y: 0)], width: 2).count, 4)
    }

    func testGhostAndSwarm() {
        var g = RigPose()
        g.ghost = 0.3
        let s = rig.compose(g)
        XCTAssertTrue(s.allSatisfy { $0.layer.hasPrefix("ghost") })
        XCTAssertTrue(s.contains { $0.ink == .stripe })
        g.ghost = 1
        XCTAssertLessThan(rig.compose(g).filter { $0.layer == "ghost" }.count, s.filter { $0.layer == "ghost" }.count / 3, "рассыпается")
        var o = RigPose()
        o.swarm = 1
        XCTAssertGreaterThanOrEqual(rig.compose(o).filter { $0.layer.hasSuffix(".pupil") && $0.layer.hasPrefix("swarm") }.count, 10)
    }

    // MARK: моменты

    func geometry() -> SceneGeometry {
        let w = CGRect(x: 300, y: 200, width: 800, height: 500)
        let s = PerchLayout.spot(window: w, above: [], visible: visible, bubble: PerchLayout.bubbleSize(chars: 30))!
        return SceneGeometry(home: CGRect(x: 740, y: 920, width: 32, height: 16), target: s.eyes, visible: visible,
                             cursor: CGPoint(x: 100, y: 100), bubble: s.bubble)
    }

    func options(seed: Int = 3) -> SceneOptions {
        var o = SceneOptions()
        o.seed = seed
        o.perchChars = 30
        return o
    }

    func testPerchUsesRigAndWavesOnArrival() {
        let g = geometry(), o = options()
        let wave = PerchTimeline.frame(PerchTimeline.arrive + 0.4, g, [], o).rig!
        XCTAssertEqual(wave.eyes, .happy)
        XCTAssertGreaterThan(wave.left.grow, 0.9)
        let after = PerchTimeline.frame(PerchTimeline.arrive + RigMoments.waveLen + 0.05, g, [], o).rig!
        XCTAssertLessThan(after.left.grow, 0.05, "руки спрятала")
        // Скучает после реплики, косится в сторону курсора (слева внизу).
        let bored = PerchTimeline.frame(PerchTimeline.speakEnd(o) + 0.3, g, [], o)
        XCTAssertEqual(bored.rig?.eyes, .half)
        XCTAssertEqual(bored.rig?.mouth, .mutter)
        XCTAssertLessThan(bored.rig!.gaze.dx, 0)
        // На входе и уходе — тоже мини-маска (а в notch — клип).
        XCTAssertNotNil(PerchTimeline.frame(0.6, g, [], o).rig)
        let d = PerchTimeline.duration(o)
        XCTAssertNotNil(PerchTimeline.frame(d - PerchTimeline.leaveLen + 0.1, g, [], o).rig)
        XCTAssertNil(PerchTimeline.frame(d - 0.1, g, [], o).rig)
        // Рот хлопает, пока печатает.
        let mouths = Set(stride(from: 1.05, to: PerchTimeline.typedAt(o), by: 1.0 / 12).compactMap {
            PerchTimeline.frame($0, g, [], o).rig?.mouth
        })
        XCTAssertEqual(mouths, [.fang, .mutter])
    }

    func testBlinksAreDeterministicBySeed() {
        let g = geometry()
        func blinks(_ seed: Int) -> [Double] {
            stride(from: 1.0, to: 12, by: 0.05).filter { (PerchTimeline.frame($0, g, [], options(seed: seed)).rig?.blink ?? 0) > 0.5 }
        }
        XCTAssertEqual(blinks(3), blinks(3))
        XCTAssertFalse(blinks(3).isEmpty)
        XCTAssertNotEqual(blinks(3), blinks(11))
    }

    func testWaveAndYawnAreDrawn() {
        let o = options()
        var t = PerchTimeline.arrive
        while t < PerchTimeline.arrive + RigMoments.waveLen - 0.1 {
            let n = PerchTimeline.step(t, o)
            XCTAssertLessThanOrEqual(n, 1.0 / 12 + 1e-3, "машет — 12 fps, t=\(t)")
            t += n
        }
    }

    func watch(_ w: SceneWatch) -> SceneOptions {
        var o = options()
        o.watch = w
        return o
    }

    func testWatchFallsAsleepAndWakesOnSay() {
        let g = geometry()
        var w = SceneWatch(window: CGRect(x: 300, y: 200, width: 800, height: 500), says: [SceneSay(at: WatchTimeline.firstSay, chars: 20)])
        let o = watch(w)
        XCTAssertEqual(WatchTimeline.frame(30, g, [], o, w).rig?.sleep, 0, "до 40 с не спит")
        let asleep = WatchTimeline.frame(WatchTimeline.arrive + RigMoments.sleepAfter + RigMoments.sleepFall + 1, g, [], o, w)
        XCTAssertEqual(asleep.phase, "sleep")
        XCTAssertEqual(asleep.rig!.sleep, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(asleep.rig!.lid, 0.85)
        XCTAssertTrue(rig.compose(asleep.rig!).contains { $0.layer.hasPrefix("z") })
        // Реплика будит.
        w.says.append(SceneSay(at: 50, chars: 10))
        let o2 = watch(w)
        XCTAssertNotEqual(WatchTimeline.frame(50.2, g, [], o2, w).phase, "sleep")
        XCTAssertEqual(WatchTimeline.frame(50.2, g, [], o2, w).rig?.sleep, 0)
        // Сон — редкие кадры (не 12 fps).
        let t = WatchTimeline.arrive + RigMoments.sleepAfter + RigMoments.sleepFall + 0.5
        XCTAssertGreaterThanOrEqual(WatchTimeline.step(t, o, SceneWatch(window: w.window, says: [w.says[0]])), 0.2)
    }

    func testWatchPointsWhileSpeakingAndGloats() {
        let g = geometry()
        var w = SceneWatch(window: CGRect(x: 300, y: 200, width: 800, height: 500), says: [SceneSay(at: WatchTimeline.firstSay, chars: 20)])
        let p = WatchTimeline.frame(WatchTimeline.firstSay + 0.4, g, [], watch(w), w).rig!
        XCTAssertGreaterThan(max(p.left.grow, p.right.grow), 0.9, "показывает пальцем в терминал")
        XCTAssertGreaterThan(p.gaze.dy, 0, "смотрит вниз, в терминал")
        w.says.append(SceneSay(at: 10, chars: 12))
        w.gloatAt = 10
        let laugh = WatchTimeline.frame(10.3, g, [], watch(w), w).rig!
        XCTAssertEqual(laugh.eyes, .squint)
        XCTAssertEqual(laugh.mouth, .jaw)
        let grin = WatchTimeline.frame(11.5, g, [], watch(w), w).rig!
        XCTAssertEqual(grin.mouth, .shark)
        XCTAssertNotEqual(grin.shake, .zero)
    }

    func testGhostWhenHostLost() {
        let g = geometry()
        var w = SceneWatch(window: CGRect(x: 300, y: 200, width: 800, height: 500), says: [SceneSay(at: WatchTimeline.firstSay, chars: 20)])
        w.ghostAt = 6
        let o = watch(w)
        XCTAssertEqual(WatchTimeline.leaveStart(w), 6 + RigMoments.ghostLen, accuracy: 1e-9)
        let f = WatchTimeline.frame(6.5, g, [], o, w)
        XCTAssertEqual(f.phase, "ghost")
        XCTAssertNil(f.bubble)
        XCTAssertGreaterThan(f.rig!.ghost, 0.3)
        XCTAssertNil(WatchTimeline.frame(6 + RigMoments.ghostLen + 0.1, g, [], o, w).eyes, "рассыпалась — дальше только молния")
    }

    func testOverloadBeforeRecall() {
        let g = geometry()
        var o = options()
        o.overload = true
        XCTAssertEqual(SceneTimeline.recallLen(.perch, o), SceneTimeline.recallDuration + RigMoments.overloadLen, accuracy: 1e-9)
        XCTAssertEqual(SceneTimeline.recallLen(.teleport, o), SceneTimeline.recallDuration)
        let f = SceneTimeline.frame(.perch, t: 4.2, geometry: g, clips: [], options: o, abortedAt: 4)
        XCTAssertEqual(f.phase, "overload")
        XCTAssertGreaterThan(f.rig!.swarm, 0.9)
        XCTAssertTrue(SceneTimeline.frame(.perch, t: 4 + SceneTimeline.recallLen(.perch, o) + 0.001, geometry: g, clips: [], options: o, abortedAt: 4).done)
        // Без перегрузки — как раньше.
        XCTAssertNotEqual(SceneTimeline.frame(.perch, t: 4.2, geometry: g, clips: [], options: options(), abortedAt: 4).phase, "overload")
    }

    func testPanelHoldsArms() {
        let g = geometry()
        let c = SceneLayout.compactPanel(.perch, geometry: g)!
        let m = PerchLayout.rigMargin(g.target.size)
        XCTAssertTrue(c.contains(g.target.insetBy(dx: -m.width, dy: -m.height)))
        // Руки при махании — в запасе (координаты рига → коробка с запасом).
        var p = RigPose()
        p.set(.wave, phase: 0.25)
        p.hair = RigMoments.hair
        let s = g.target.width / rig.size.width
        for sh in rig.compose(p) where sh.layer.hasPrefix("arm") || sh.layer.hasPrefix("finger") {
            let b = sh.bounds
            XCTAssertGreaterThan(b.minX * s, -m.width)
            XCTAssertGreaterThan(b.minY * s, -m.height)
        }
    }
}
