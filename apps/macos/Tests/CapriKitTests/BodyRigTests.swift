import XCTest
import CoreGraphics
@testable import CapriKit

final class BodyRigTests: XCTestCase {
    let b = BodyRig.standardBones

    func dist(_ a: CGPoint, _ c: CGPoint) -> Double { Double(hypot(a.x - c.x, a.y - c.y)) }

    func testIKReachesTargetAndKeepsLengths() {
        let root = CGPoint(x: 3, y: -5)
        for (t, bend) in [(CGPoint(x: 20, y: 30), 1.0), (CGPoint(x: -25, y: 10), -1.0), (CGPoint(x: 0, y: -40), 1.0)] {
            let (a1, a2) = BodyIK.solve(root: root, target: t, l1: 24, l2: 23, bend: bend)
            let j = BodyIK.step(root, a1, 24)
            let end = BodyIK.step(j, a2, 23)
            XCTAssertEqual(dist(end, t), 0, accuracy: 1e-6)
            XCTAssertEqual(dist(root, j), 24, accuracy: 1e-9)
        }
    }

    func testIKBendSidesAreMirror() {
        let root = CGPoint.zero, t = CGPoint(x: 0, y: 40)
        let (p1, _) = BodyIK.solve(root: root, target: t, l1: 24, l2: 23, bend: 1)
        let (m1, _) = BodyIK.solve(root: root, target: t, l1: 24, l2: 23, bend: -1)
        // Цель прямо вниз: +1 — колено влево (по часовой на экране), −1 — вправо.
        XCTAssertLessThan(BodyIK.step(root, p1, 24).x, 0)
        XCTAssertGreaterThan(BodyIK.step(root, m1, 24).x, 0)
    }

    func testIKUnreachableStretchesTowardTarget() {
        let (a1, a2) = BodyIK.solve(root: .zero, target: CGPoint(x: 100, y: 0), l1: 24, l2: 23, bend: 1)
        XCTAssertEqual(a1, 0, accuracy: 0.1)
        XCTAssertEqual(a2, 0, accuracy: 0.1)
    }

    func testFallbackIsValidAndRoundTrips() throws {
        XCTAssertEqual(BodyRig.fallback.problems, [])
        let data = try JSONEncoder().encode(BodyRig.fallback)
        XCTAssertEqual(BodyRig.decode(data), BodyRig.fallback)
        XCTAssertNil(BodyRig.decode(Data("{}".utf8)))
    }

    func testStandingToesTouchGround() {
        let sk = BodyRig.fallback.skeleton(BodyMoves.idle(0, b))
        for i in 0..<2 { XCTAssertEqual(Double(sk.toes[i].y), 0, accuracy: 1.0) }
    }

    func testSitKeepsSeatAndHandsOnEdge() {
        for t in stride(from: 0.0, to: 3, by: 0.37) {
            let sk = BodyRig.fallback.skeleton(BodyMoves.sit(t, b))
            XCTAssertEqual(Double(sk.seat.y), 0.5, accuracy: 1e-6)
            XCTAssertEqual(Double(sk.wrists[0].y), -1.8, accuracy: 0.6)
            // Ноги свисают ниже края.
            for i in 0..<2 { XCTAssertGreaterThan(sk.toes[i].y, 20, "свисают и при широком махе") }
        }
    }

    func testSitSwingMovesFeetInAntiphase() {
        let a = BodyRig.fallback.skeleton(BodyMoves.sit(0, b))
        let c = BodyRig.fallback.skeleton(BodyMoves.sit(BodyMoves.swingPeriod / 4, b))
        let d0 = c.toes[0].x - a.toes[0].x, d1 = c.toes[1].x - a.toes[1].x
        XCTAssertLessThan(d0 * d1, 0)
    }

    func testHangPinsWristUnderEdge() {
        for t in [0.0, 0.5, 1.3] {
            let sk = BodyRig.fallback.skeleton(BodyMoves.hang(t, b))
            XCTAssertEqual(Double(sk.wrists[1].x), 0, accuracy: 1e-6)
            XCTAssertGreaterThan(sk.toes[0].y, 100)
        }
    }

    func testLeanHandOnSill() {
        let sk = BodyRig.fallback.skeleton(BodyMoves.lean(0, b))
        XCTAssertLessThan(dist(sk.wrists[1], BodyMoves.sill), 0.5)
    }

    func testWalkPlantedFootDoesNotSlide() {
        // Нога 0 в опоре при phase 0…0,5: щиколотка стоит на месте.
        let a = BodyRig.fallback.skeleton(BodyMoves.walk(0.05, b))
        let c = BodyRig.fallback.skeleton(BodyMoves.walk(0.4, b))
        XCTAssertEqual(Double(a.ankles[0].x), Double(c.ankles[0].x), accuracy: 0.01)
        XCTAssertGreaterThan(c.waist.x, a.waist.x)
    }

    func testDanceRepeatsEveryTwoBars() {
        let a = BodyMoves.dance(1.3, b), c = BodyMoves.dance(9.3, b)
        XCTAssertEqual(Double(a.waist.x), Double(c.waist.x), accuracy: 1e-6)
        for i in 0..<2 { XCTAssertEqual(a.arms[i].upper, c.arms[i].upper, accuracy: 1e-6) }
        // Приседание — на долю.
        XCTAssertGreaterThan(BodyMoves.dance(2.0, b).waist.y, BodyMoves.dance(2.5, b).waist.y)
    }

    func testMeltFlattensAndLeaves() {
        let rig = BodyRig.fallback
        let puddle = rig.compose(BodyMoves.melt(1, b))
        let body = puddle.filter { !$0.layer.hasPrefix("face.") && $0.layer != "sparkle" && !$0.layer.hasPrefix("splash") }
        let top = body.map { $0.bounds.minY }.min() ?? 0
        XCTAssertGreaterThan(top, -20)
        // Брызги: торчащие вверх осколки и зелёные треугольники маски в луже.
        let splash = puddle.filter { $0.layer.hasPrefix("splash") }
        XCTAssertGreaterThanOrEqual(splash.filter { $0.ink == .hair }.count, 4)
        XCTAssertGreaterThanOrEqual(splash.filter { $0.ink == .mask }.count, 2)
        XCTAssertLessThan(splash.map { $0.bounds.minY }.min() ?? 0, -8, "осколки стоят торчком")
        // Растекается, а не сжимается: на .4 голова ещё высоко, низ уже шире стойки.
        let mid = rig.compose(BodyMoves.melt(0.4, b)).filter { $0.layer != "sparkle" }
        let stand = rig.compose(BodyMoves.idle(0, b)).filter { $0.layer != "sparkle" }
        func bounds(_ x: [RigShape]) -> CGRect { x.reduce(CGRect.null) { $0.union($1.bounds) } }
        XCTAssertGreaterThan(bounds(mid).width, bounds(stand.filter { !$0.layer.hasPrefix("hair") }).width)
        let gone = rig.compose(BodyMoves.melt(2, b)).filter { !$0.layer.hasPrefix("face.") && $0.opacity > 0.01 && $0.layer != "sparkle" }
        XCTAssertTrue(gone.isEmpty, gone.map(\.layer).joined(separator: ","))
    }

    func testHairMassIsWiderThanBody() {
        let shapes = BodyRig.fallback.compose(BodyMoves.idle(0, b))
        let hair = shapes.filter { $0.layer.hasPrefix("hair") }.reduce(CGRect.null) { $0.union($1.bounds) }
        let chest = shapes.filter { $0.layer.hasPrefix("chest") }.reduce(CGRect.null) { $0.union($1.bounds) }
        XCTAssertGreaterThan(hair.width, 3 * chest.width)
        let all = shapes.reduce(CGRect.null) { $0.union($1.bounds) }
        XCTAssertGreaterThan(all.height, 150)
        XCTAssertLessThan(all.height, 210)
    }

    func testSparklesCappedAndArmsOutlined() {
        let shapes = BodyRig.fallback.compose(BodyMoves.dance(4.1, b))
        XCTAssertLessThanOrEqual(shapes.filter { $0.layer == "sparkle" }.count, BodyRig.maxSparkles)
        let sparse = BodyRig.fallback.compose(BodyMoves.dance(4.1, b), sparkle: 0.3).filter { $0.layer == "sparkle" }.count
        XCTAssertLessThan(sparse, shapes.filter { $0.layer == "sparkle" }.count, "мелкий масштаб — меньше блёсток")
        // Руки — с чернильным контуром (не сливаются с волосами), ноги — без.
        XCTAssertTrue(shapes.contains { $0.layer.hasPrefix("upperArm") && $0.layer.hasSuffix(".outline") && $0.ink == .ink })
        XCTAssertFalse(shapes.contains { $0.layer.hasPrefix("thigh") && $0.layer.hasSuffix(".outline") })
    }

    func testMalformedPoseDoesNotCrash() {
        var p = BodyMoves.idle(0, b)
        p.arms = [p.arms[0]]
        p.handAt = []
        p.kneeBend = []
        XCTAssertFalse(BodyRig.fallback.compose(p).isEmpty)
        var bad = BodyRig.fallback
        bad.hair[0].points[0] = [.nan, 0]
        XCTAssertFalse(bad.problems.isEmpty, "NaN в волосах — риг не грузится")
        XCTAssertEqual(BodyRig.fallback.height, 28 + 5 + 12 + 6 + 33 + 35 + 9, accuracy: 1e-9)
    }

    func testSparklesChangeWithTickShapesDoNot() {
        var p = BodyMoves.idle(0, b)
        let a = BodyRig.fallback.compose(p)
        p.tick += 1
        let c = BodyRig.fallback.compose(p)
        XCTAssertEqual(a.filter { $0.layer != "sparkle" }, c.filter { $0.layer != "sparkle" })
        XCTAssertNotEqual(a.filter { $0.layer == "sparkle" }, c.filter { $0.layer == "sparkle" })
    }

    func testFlipMirrorsAboutWaist() {
        var p = BodyMoves.lean(0, b)
        let a = BodyRig.fallback.compose(p).filter { $0.layer != "sparkle" }
        p.flip = true
        let c = BodyRig.fallback.compose(p).filter { $0.layer != "sparkle" }
        XCTAssertEqual(a.count, c.count)
        let x0 = BodyRig.fallback.skeleton(p).waist.x
        XCTAssertEqual(Double(a[3].points[0].x - x0), Double(x0 - c[3].points[0].x), accuracy: 1e-6)
    }

    func testCatalogAllFramesCompose() {
        for f in BodyMoves.catalog(b) + BodyMoves.danceStrip(b) + BodyMoves.swingStrip(b) {
            let shapes = BodyRig.fallback.compose(f.pose)
            XCTAssertFalse(shapes.isEmpty, f.name)
            XCTAssertTrue(shapes.allSatisfy { $0.points.allSatisfy { $0.x.isFinite && $0.y.isFinite } }, f.name)
        }
    }

    /// Для итераций рисунка: `CAPRI_BODY_DUMP=/path.json` — фигуры всех кадров листа в JSON (риг из
    /// `CAPRI_BODY_ART`, лицо из `CAPRI_FACE_ART`, иначе фолбэки).
    func testDumpForPreview() throws {
        guard let out = ProcessInfo.processInfo.environment["CAPRI_BODY_DUMP"] else { return }
        let env = ProcessInfo.processInfo.environment
        let rig = env["CAPRI_BODY_ART"].flatMap { BodyRig.load(URL(fileURLWithPath: $0)) } ?? .fallback
        let face = env["CAPRI_FACE_ART"].flatMap { CapriRig.load(URL(fileURLWithPath: $0)) } ?? .fallback
        func frames(_ fs: [BodyFrame]) -> [[String: Any]] {
            fs.map { f in
                ["name": f.name, "stage": f.stage.rawValue,
                 "shapes": rig.compose(f.pose, face: face).map { s in
                     ["ink": s.ink.rawValue, "o": s.opacity, "p": s.points.map { [Double($0.x), Double($0.y)] }] as [String: Any]
                 }]
            }
        }
        let obj: [String: Any] = ["rig": rig.name, "catalog": frames(BodyMoves.catalog(rig.bones)),
                                  "dance": frames(BodyMoves.danceStrip(rig.bones)), "swing": frames(BodyMoves.swingStrip(rig.bones))]
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: out))
    }
}
