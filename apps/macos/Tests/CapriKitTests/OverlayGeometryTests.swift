import XCTest
import CoreGraphics
@testable import CapriKit

final class OverlayGeometryTests: XCTestCase {
    func testWindowReturnsToVisibleAreaOnNegativeOriginMonitor() {
        let result = OverlayGeometry.clampedOrigin(
            CGPoint(x: -2000, y: 1200), panelSize: CGSize(width: 200, height: 280),
            visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 900)
        )
        XCTAssertEqual(result, CGPoint(x: -1440, y: 620))
    }

    func testPanelLargerThanDisplayHasFiniteOrigin() {
        let result = OverlayGeometry.clampedOrigin(.zero, panelSize: CGSize(width: 500, height: 800),
            visibleFrame: CGRect(x: 30, y: 40, width: 300, height: 200))
        XCTAssertEqual(result, CGPoint(x: 30, y: 40))
    }

    func testTransparentPixelsPassThroughAndNativeYIsFlipped() {
        let map = SpriteHitMap(width: 2, height: 2, alpha: [255, 0, 0, 255])
        XCTAssertTrue(map.contains(CGPoint(x: 25, y: 75), canvasSize: CGSize(width: 100, height: 100)))
        XCTAssertFalse(map.contains(CGPoint(x: 75, y: 75), canvasSize: CGSize(width: 100, height: 100)))
        XCTAssertFalse(map.contains(CGPoint(x: -1, y: 50), canvasSize: CGSize(width: 100, height: 100)))
        XCTAssertFalse(map.contains(CGPoint(x: 100, y: 100), canvasSize: CGSize(width: 100, height: 100)))
    }

    func testHideExpiresAtOneHourAndSurvivesRecreation() {
        let now = Date(timeIntervalSince1970: 1000)
        let until = OverlayPreferences.hiddenDeadline(from: now)
        XCTAssertEqual(until.timeIntervalSince1970, 4600)
        XCTAssertTrue(OverlayPreferences.isHidden(until: until, now: Date(timeIntervalSince1970: 4599)))
        XCTAssertFalse(OverlayPreferences.isHidden(until: until, now: Date(timeIntervalSince1970: 4600)))
    }
}
