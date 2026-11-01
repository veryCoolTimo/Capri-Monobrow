import XCTest
import CoreGraphics
@testable import CapriKit

final class TransitionsTests: XCTestCase {
    let from = CGRect(x: 900, y: 300, width: 120, height: 60)
    let to = CGRect(x: 600, y: 950, width: 32, height: 16)

    func testStartAndEndAreExact() {
        for kind in TransitionKind.allCases {
            for role in [TransitionRole.enter, .exit] {
                for seed in [0, 7, 991] {
                    let a = Transitions.frame(kind, role, t: 0, len: 0.3, from: from, to: to, seed: seed)
                    let z = Transitions.frame(kind, role, t: 0.3, len: 0.3, from: from, to: to, seed: seed)
                    XCTAssertEqual(a, Transitions.start(kind, role, from: from, to: to), "\(kind) \(role)")
                    XCTAssertEqual(z, Transitions.end(kind, role, from: from, to: to), "\(kind) \(role)")
                }
            }
            // Выход начинается с содержимого на месте, вход им заканчивается; молния — ни там, ни там.
            XCTAssertEqual(Transitions.start(kind, .exit, from: from, to: to).plain, kind != .boltChain)
            XCTAssertEqual(Transitions.end(kind, .enter, from: from, to: to).plain, kind != .boltChain)
            XCTAssertTrue(Transitions.end(kind, .exit, from: from, to: to).hidden)
            XCTAssertTrue(Transitions.start(kind, .enter, from: from, to: to).hidden)
        }
    }

    func testBarsAreContinuousNearTheEnds() {
        // Чуть после начала выхода — все полосы на месте и почти без сдвига; чуть до конца входа — тоже.
        let early = Transitions.frame(.glitchBars, .exit, progress: 0.02, tick: 3, from: from, to: to, seed: 5)
        let late = Transitions.frame(.glitchBars, .enter, progress: 0.98, tick: 3, from: from, to: to, seed: 5)
        for f in [early, late] {
            XCTAssertTrue(f.bars.allSatisfy { $0.shown })
            XCTAssertTrue(f.bars.allSatisfy { abs($0.dx) < 2 })
            XCTAssertEqual(f.bars.reduce(0) { $0 + $1.h }, 1, accuracy: 1e-6, "полосы закрывают всю высоту")
        }
        // Почти конец выхода — полосы разлетелись и почти все пропали.
        let gone = Transitions.frame(.glitchBars, .exit, progress: 0.95, tick: 3, from: from, to: to, seed: 5)
        XCTAssertTrue(gone.bars.allSatisfy { !$0.shown })
        let smear = Transitions.frame(.columnSmear, .exit, progress: 0.5, tick: 0, from: from, to: to, seed: 5)
        XCTAssertTrue(smear.columns.contains { $0.drop > 0 && $0.stretch > 1 })
        let rise = Transitions.frame(.columnSmear, .enter, progress: 0.5, tick: 0, from: from, to: to, seed: 5)
        XCTAssertTrue(rise.columns.contains { $0.drop < 0 }, "вход — натекает сверху")
    }

    func testBurstFlashAndReduceMotion() {
        let f = Transitions.frame(.burstIn, .enter, progress: 0.1, tick: 0, from: from, to: from, seed: 4)
        XCTAssertNil(f.rect, "сначала только вспышка")
        XCTAssertEqual(f.flash?.alpha, 1)
        XCTAssertTrue(f.flash!.rect.contains(from))
        let calm = Transitions.frame(.burstIn, .enter, progress: 0.1, tick: 0, from: from, to: from, seed: 4, reduceMotion: true)
        XCTAssertNil(calm.flash)
        XCTAssertFalse(calm.bars.isEmpty)
        XCTAssertEqual(Transitions.pick(.enter, seed: 1, reduceMotion: true), .glitchBars)
        XCTAssertEqual(Transitions.pick(.exit, seed: 1, avoid: .glitchBars, reduceMotion: true), .glitchBars)
    }

    func testRibbonFliesToTarget() {
        let squash = Transitions.frame(.ribbonOut, .exit, progress: 0.15, tick: 0, from: from, to: to, seed: 2)
        XCTAssertLessThan(squash.squash, 1)
        XCTAssertNil(squash.ribbon)
        let mid = Transitions.frame(.ribbonOut, .exit, progress: 0.7, tick: 0, from: from, to: to, seed: 2)
        XCTAssertNil(mid.rect)
        let r = mid.ribbon!
        XCTAssertEqual(r.points.first, CGPoint(x: from.midX, y: from.midY))
        XCTAssertEqual(r.points.last, CGPoint(x: to.midX, y: to.midY))
        XCTAssertLessThan(r.tail, r.head)
    }

    func testBoltSegmentsConnectAndStayShort() {
        let a = CGPoint(x: 600, y: 958), b = CGPoint(x: 1100, y: 330)
        for seed in 0..<60 {
            let bolt = Transitions.bolt(from: a, to: b, seed: seed)!
            XCTAssertEqual(bolt.main.first, a)
            XCTAssertEqual(bolt.main.last, b)
            let main = zip(bolt.main, bolt.main.dropFirst()).map { BoltSegment(a: $0, b: $1) }
            for (s, n) in zip(main, main.dropFirst()) { XCTAssertEqual(s.b, n.a) }
            for s in main {
                XCTAssertLessThanOrEqual(s.length, Transitions.segmentMax, "seed \(seed)")
                XCTAssertGreaterThanOrEqual(s.length, 8, "seed \(seed)")
            }
            XCTAssertGreaterThanOrEqual(main.count, 10, "короткие прямые отрезки")
            XCTAssertFalse(bolt.branches.isEmpty, "ответвления")
            for br in bolt.branches {
                XCTAssertTrue(bolt.main.dropFirst().dropLast().contains(br[0]), "ответвление растёт из вершины")
                XCTAssertTrue((3...4).contains(br.count))
                for (p, q) in zip(br, br.dropFirst()) { XCTAssertLessThanOrEqual(BoltSegment(a: p, b: q).length, Transitions.segmentMax) }
            }
            XCTAssertEqual(bolt.segments.count, main.count + bolt.branches.reduce(0) { $0 + $1.count - 1 })
        }
        XCTAssertNil(Transitions.bolt(from: a, to: a, seed: 1))
        XCTAssertNil(Transitions.bolt(from: a, to: b, seed: 1, reach: 0))
    }

    func testBoltDeterministicAndReach() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 400, y: 0)
        XCTAssertEqual(Transitions.bolt(from: a, to: b, seed: 42), Transitions.bolt(from: a, to: b, seed: 42))
        XCTAssertNotEqual(Transitions.bolt(from: a, to: b, seed: 42), Transitions.bolt(from: a, to: b, seed: 43))
        let half = Transitions.bolt(from: a, to: b, seed: 42, reach: 0.5)!
        let full = Transitions.bolt(from: a, to: b, seed: 42)!
        func length(_ pts: [CGPoint]) -> CGFloat { zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
        XCTAssertEqual(length(half.main), length(full.main) / 2, accuracy: 0.5)
        XCTAssertLessThan(half.main.last!.x, 260)
        // Перелёт молнией: глаз нет, молния кипит раз в два тика.
        let f1 = Transitions.frame(.boltChain, .exit, progress: 0.5, tick: 4, from: from, to: to, seed: 1)
        let f2 = Transitions.frame(.boltChain, .exit, progress: 0.5, tick: 5, from: from, to: to, seed: 1)
        let f3 = Transitions.frame(.boltChain, .exit, progress: 0.5, tick: 6, from: from, to: to, seed: 1)
        XCTAssertNil(f1.rect)
        XCTAssertEqual(f1.bolt, f2.bolt)
        XCTAssertNotEqual(f1.bolt, f3.bolt)
    }

    func testPickNeverRepeatsTwiceInARow() {
        for role in [TransitionRole.enter, .exit] {
            var prev: TransitionKind?
            var seen: Set<TransitionKind> = []
            for seed in 0..<300 {
                let k = Transitions.pick(role, seed: seed, avoid: prev)
                XCTAssertNotEqual(k, prev)
                XCTAssertTrue(Transitions.options(role).contains(k))
                XCTAssertEqual(k, Transitions.pick(role, seed: seed, avoid: prev), "тот же seed — тот же вид")
                seen.insert(k)
                prev = k
            }
            XCTAssertEqual(seen, Set(Transitions.options(role)))
        }
        XCTAssertFalse(Transitions.options(.enter).contains(.ribbonOut))
        XCTAssertFalse(Transitions.options(.exit).contains(.burstIn))
    }
}
