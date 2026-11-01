import XCTest
import CoreGraphics
@testable import CapriKit

final class SpaceSweepTests: XCTestCase {
    // Как в notch: глаза 32×16 в 13 pt от левого края капли, крыло до выреза — 76 pt.
    let eyes = CGRect(x: 13, y: 8, width: 32, height: 16)
    let lane: ClosedRange<CGFloat> = 0...76
    let uuid = "AAAAAAAA-0000-0000-0000-000000000001"

    /// Как отдаёт WindowServer (структура с настоящего Мака, id и UUID обезличены).
    func raw(current: Int, display: String? = nil, spaces: [(Int, Int)] = [(3, 0), (16, 0), (3983, 4), (44, 4), (20, 0)]) -> [[String: Any]] {
        [[
            "Display Identifier": display ?? uuid,
            "Current Space": ["ManagedSpaceID": NSNumber(value: current), "id64": NSNumber(value: current), "type": NSNumber(value: 0)],
            "Spaces": spaces.map { id, type -> [String: Any] in
                var s: [String: Any] = ["ManagedSpaceID": NSNumber(value: id), "id64": NSNumber(value: id), "type": NSNumber(value: type),
                                        "uuid": "space-\(id)"]
                if type == 4 { s["TileLayoutManager"] = ["x": 1]; s["pid"] = NSNumber(value: 1) }
                return s
            }
        ]]
    }

    func testParseReadsOrderCurrentAndFullscreen() {
        let s = SpaceSnapshot.parse(raw(current: 3983))
        XCTAssertEqual(s.displays.count, 1)
        XCTAssertEqual(s.displays[0].spaces.map(\.id), [3, 16, 3983, 44, 20])
        XCTAssertEqual(s.displays[0].spaces.map(\.fullscreen), [false, false, true, true, false])
        XCTAssertEqual(s.displays[0].current, 3983)
        XCTAssertEqual(s.display(uuid)?.currentSpace?.fullscreen, true)
        // Мусор не роняет разбор.
        XCTAssertEqual(SpaceSnapshot.parse([["x": 1], ["Display Identifier": "Main", "Spaces": [["foo": 1]]]]).displays,
                       [DisplaySpaces(display: "Main", spaces: [], current: nil)])
    }

    func testDirectionFromIndexInDisplayList() {
        let a = SpaceSnapshot.parse(raw(current: 16)), right = SpaceSnapshot.parse(raw(current: 3983)), left = SpaceSnapshot.parse(raw(current: 3))
        XCTAssertEqual(Spaces.change(from: a, to: right, display: uuid), .moved(.forward, fullscreen: true))
        XCTAssertEqual(Spaces.change(from: a, to: left, display: uuid), .moved(.backward, fullscreen: false))
        // Через несколько пространств сразу (Ctrl-цифра, переход к приложению) — тоже по индексу.
        XCTAssertEqual(Spaces.change(from: left, to: SpaceSnapshot.parse(raw(current: 20)), display: uuid), .moved(.forward, fullscreen: false))
        // Без снимка до, без приватных функций — неизвестно.
        XCTAssertEqual(Spaces.change(from: nil, to: right, display: uuid), .moved(.unknown, fullscreen: true))
        XCTAssertEqual(Spaces.change(from: a, to: nil, display: uuid), .moved(.unknown, fullscreen: nil))
        // Ничего не поменялось — всё равно что-то ехало (неизвестно куда).
        XCTAssertEqual(Spaces.change(from: a, to: a, display: uuid), .moved(.unknown, fullscreen: false))
    }

    func testClosedFullscreenSpaceUsesOldIndex() {
        // Ушли из полноэкранного, и его пространство исчезло — индекс прежнего берём из старого списка.
        let before = SpaceSnapshot.parse(raw(current: 44))
        let after = SpaceSnapshot.parse(raw(current: 3983, spaces: [(3, 0), (16, 0), (3983, 4), (20, 0)]))
        XCTAssertEqual(Spaces.change(from: before, to: after, display: uuid), .moved(.backward, fullscreen: true))
    }

    func testOtherDisplayAndSharedSpaces() {
        let other = "BBBBBBBB-0000-0000-0000-000000000002"
        func two(_ ours: Int, _ theirs: Int) -> SpaceSnapshot {
            SpaceSnapshot.parse(raw(current: ours) + raw(current: theirs, display: other, spaces: [(7, 0), (8, 0)]))
        }
        XCTAssertEqual(Spaces.change(from: two(16, 7), to: two(16, 8), display: uuid), .elsewhere)
        XCTAssertEqual(Spaces.change(from: two(16, 7), to: two(3, 7), display: uuid), .moved(.backward, fullscreen: false))
        // «У дисплеев общие пространства»: одна запись `Main` при любом UUID notch.
        let main = { SpaceSnapshot.parse(self.raw(current: $0, display: "Main")) }
        XCTAssertEqual(Spaces.change(from: main(3), to: main(16), display: uuid), .moved(.forward, fullscreen: false))
    }

    func testEyesMoveWithTheDesk() {
        XCTAssertEqual(SpaceMove.forward.eyesDirection, -1)   // правее в Mission Control — стол уезжает влево
        XCTAssertEqual(SpaceMove.backward.eyesDirection, 1)
        XCTAssertEqual(SpaceMove.unknown.eyesDirection, 0)
    }

    // MARK: кривая

    func styles() -> [SpaceSweepStyle] {
        SpaceMove.allCases.flatMap { m in [false, true].flatMap { soft in [false, true].map { r in
            SpaceSweepStyle(move: m, soft: soft, reduceMotion: r, seed: 5)
        } } }
    }

    func testStartsAndEndsPlain() {
        for s in styles() {
            let d = SpaceSweep.duration(s)
            for t in [-1, 0, d, d + 0.5] {
                XCTAssertTrue(SpaceSweep.frame(t: t, style: s, eyes: eyes, lane: lane).plain, "\(s) t=\(t)")
            }
            // Почти в конце — почти на месте.
            let late = SpaceSweep.frame(t: d - 0.005, style: s, eyes: eyes, lane: lane)
            XCTAssertLessThan(abs(late.dx), 0.5, "\(s)")
            XCTAssertEqual(late.scaleX, 1, accuracy: 0.02)
            XCTAssertEqual(late.alpha, 1, accuracy: 0.05)
            XCTAssertTrue(late.bars.isEmpty)
        }
        XCTAssertEqual(SpaceSweep.length, 0.42)
        XCTAssertGreaterThanOrEqual(SpaceSweep.length, 0.35)
        XCTAssertLessThanOrEqual(SpaceSweep.length, 0.45)
    }

    func testHiddenInTheMiddle() {
        for s in styles() {
            let mid = s.reduceMotion ? 0.16 : 0.18
            XCTAssertFalse(SpaceSweep.frame(t: mid, style: s, eyes: eyes, lane: lane).visible, "\(s)")
        }
    }

    func testSweepsOutPastTheEdgeAndInFromTheOtherSide() {
        for (move, sign) in [(SpaceMove.forward, CGFloat(-1)), (.backward, 1)] {
            let s = SpaceSweepStyle(move: move, seed: 3)
            let out = SpaceSweep.frame(t: 0.155, style: s, eyes: eyes, lane: lane)
            XCTAssertEqual(out.dx.sign, sign.sign)
            // Растянутые глаза целиком за краем крыла.
            let half = eyes.width * out.scaleX / 2
            if sign < 0 { XCTAssertLessThan(eyes.midX + out.dx + half, lane.lowerBound + 2) }
            else { XCTAssertGreaterThan(eyes.midX + out.dx - half, lane.upperBound - 2) }
            XCTAssertFalse(out.bars.isEmpty)
            // Полосы и копии тянутся назад.
            XCTAssertTrue(out.ghosts.allSatisfy { $0.dx.sign == (-sign).sign })
            let back = out.bars.filter { $0.dx != 0 && $0.dx.sign == (-sign).sign }.count
            XCTAssertGreaterThan(back, out.bars.count / 2)
            // Вход — с другой стороны, едет в ту же сторону.
            let enter = SpaceSweep.frame(t: 0.22, style: s, eyes: eyes, lane: lane)
            XCTAssertEqual(enter.dx.sign, (-sign).sign)
            let later = SpaceSweep.frame(t: 0.28, style: s, eyes: eyes, lane: lane)
            XCTAssertLessThan(abs(later.dx), abs(enter.dx))
        }
    }

    func testSmallOvershoot() {
        for move in [SpaceMove.forward, .backward] {
            let s = SpaceSweepStyle(move: move)
            let dir = move.eyesDirection
            let over = stride(from: 0.2, to: 0.42, by: 0.002).map { SpaceSweep.frame(t: $0, style: s, eyes: eyes, lane: lane).dx * dir }.max()!
            XCTAssertGreaterThan(over, 0.8, "\(move): садится с перелётом")
            XCTAssertLessThanOrEqual(over, SpaceSweep.overshootMax + 0.05)
        }
    }

    func testSoftArrivalSquintsWithoutGlitch() {
        for move in SpaceMove.allCases {
            let s = SpaceSweepStyle(move: move, soft: true)
            for t in stride(from: 0.2, to: 0.42, by: 0.01) {
                let f = SpaceSweep.frame(t: t, style: s, eyes: eyes, lane: lane)
                XCTAssertTrue(f.bars.isEmpty && f.ghosts.isEmpty, "\(move) t=\(t)")
                XCTAssertLessThanOrEqual(f.dx * move.eyesDirection, 0.001, "без перелёта")
            }
            XCTAssertEqual(SpaceSweep.frame(t: 0.25, style: s, eyes: eyes, lane: lane).squint, 1)
        }
    }

    func testUnknownIsSymmetric() {
        let s = SpaceSweepStyle(move: .unknown, seed: 9)
        for t in stride(from: 0.01, to: 0.42, by: 0.01) {
            let f = SpaceSweep.frame(t: t, style: s, eyes: eyes, lane: lane)
            XCTAssertEqual(f.dx, 0)
            XCTAssertEqual(f.ghosts.map(\.dx).reduce(0, +), 0, accuracy: 0.001)
        }
        XCTAssertLessThan(SpaceSweep.frame(t: 0.155, style: s, eyes: eyes, lane: lane).scaleX, 0.15)
    }

    func testReduceMotionOnlyFades() {
        let s = SpaceSweepStyle(move: .forward, reduceMotion: true)
        for t in stride(from: 0.0, to: 0.4, by: 0.01) {
            let f = SpaceSweep.frame(t: t, style: s, eyes: eyes, lane: lane)
            XCTAssertEqual(f.dx, 0); XCTAssertEqual(f.scaleX, 1); XCTAssertTrue(f.bars.isEmpty && f.ghosts.isEmpty)
        }
        XCTAssertEqual(SpaceSweep.frame(t: 0.07, style: s, eyes: eyes, lane: lane).alpha, 0.5, accuracy: 0.01)
    }

    func testDeterministic() {
        let s = SpaceSweepStyle(move: .backward, seed: 42)
        for t in [0.05, 0.1, 0.25, 0.33] {
            XCTAssertEqual(SpaceSweep.frame(t: t, style: s, eyes: eyes, lane: lane), SpaceSweep.frame(t: t, style: s, eyes: eyes, lane: lane))
        }
    }

    // MARK: быстрые свайпы подряд

    func testCoalesce() {
        let fwd = SpaceSweepStyle(move: .forward, seed: 1)
        let a = SpaceSweep.coalesce(nil, now: 100, style: fwd)
        XCTAssertEqual(a, SpaceSweepRun(start: 100, style: fwd))
        // Ещё уходят — тот же эффект, тон входа — по последнему пространству.
        let b = SpaceSweep.coalesce(a, now: 100.1, style: SpaceSweepStyle(move: .backward, soft: true, seed: 2))
        XCTAssertEqual(b.start, 100)
        XCTAssertEqual(b.style.move, .forward)
        XCTAssertTrue(b.style.soft)
        // Уже входят — снова «их нет», вход в сторону последнего.
        let c = SpaceSweep.coalesce(b, now: 100.3, style: SpaceSweepStyle(move: .backward, seed: 3))
        XCTAssertEqual(c.start, 100.3 - SpaceSweep.hidden(c.style), accuracy: 1e-9)
        XCTAssertEqual(c.style.move, .backward)
        XCTAssertFalse(SpaceSweep.frame(t: 100.3 - c.start, style: c.style, eyes: eyes, lane: lane).visible)
        // Пять свайпов за секунду — эффект кончается вскоре после последнего, не через 5 × 0,42 с.
        var run: SpaceSweepRun?
        for k in 0..<5 { run = SpaceSweep.coalesce(run, now: 200 + Double(k) * 0.2, style: fwd) }
        XCTAssertLessThanOrEqual(run!.end, 200.8 + SpaceSweep.length)
        // Кончился — новый.
        XCTAssertEqual(SpaceSweep.coalesce(a, now: 101, style: fwd).start, 101)
        // Только вход: начинается невидимым.
        let arr = SpaceSweep.arriving(now: 50, style: fwd)
        XCTAssertFalse(SpaceSweep.frame(t: 50 - arr.start, style: fwd, eyes: eyes, lane: lane).visible)
    }
}
