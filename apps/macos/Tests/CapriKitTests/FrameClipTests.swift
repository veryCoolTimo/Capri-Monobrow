import XCTest
@testable import CapriKit

final class FrameClipTests: XCTestCase {
    let clip = FrameClip(frames: [10, 11, 12], holds: [3, 1, 2])

    func testHoldsAndLoop() {
        XCTAssertEqual(clip.total, 6)
        XCTAssertEqual((0..<8).map { clip.frame(at: $0, loop: true) }, [10, 10, 10, 11, 12, 12, 10, 10])
        XCTAssertEqual(clip.frame(at: 100, loop: false), 12)
        XCTAssertEqual(clip.frame(at: -5, loop: true), 10)
        XCTAssertNil(FrameClip(frames: [], holds: []).frame(at: 0, loop: true))
    }

    func testCapHoldConcat() {
        XCTAssertEqual(clip.capped(1).holds, [1, 1, 1])
        XCTAssertEqual(clip.holdingLast(9).holds, [3, 1, 9])
        let both = clip.capped(1) + FrameClip(frames: [20], holds: [0])
        XCTAssertEqual(both.holds, [1, 1, 1, 1])
        XCTAssertEqual(both.frame(at: 3, loop: false), 20)
    }

    func testHugeHoldsDoNotOverflow() {
        let huge = FrameClip(frames: [1, 2], holds: [Int.max, Int.max]) + FrameClip(frames: [3], holds: [Int.max])
        XCTAssertEqual(huge.total, 3 * FrameClip.maxHold)
        XCTAssertEqual(huge.frame(at: Int.max, loop: true).map { [1, 2, 3].contains($0) }, true)
    }

    func testBurstOncePerPeriod() {
        for beat in 0..<20 {
            let hits = (beat * 30..<(beat + 1) * 30).filter { TickNoise.burst($0, period: 30, length: 2) != nil }
            XCTAssertEqual(hits.count, 2)
            XCTAssertEqual(hits[1] - hits[0], 1)
        }
        XCTAssertNil(TickNoise.burst(5, period: 2, length: 2))
        XCTAssertEqual(TickNoise.unit(7, 3), TickNoise.unit(7, 3))
    }
}
