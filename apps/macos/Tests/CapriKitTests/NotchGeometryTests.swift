import XCTest
import CoreGraphics
@testable import CapriKit

final class NotchGeometryTests: XCTestCase {
    // Встроенный дисплей MacBook Pro M4 Pro (1512×982 pt), значения сняты NotchSpike 2026-10-29.
    private let builtIn = NotchScreen(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
        safeAreaTop: 32,
        auxiliaryTopLeft: CGRect(x: 0, y: 950, width: 663.5, height: 32),
        auxiliaryTopRight: CGRect(x: 848.5, y: 950, width: 663.5, height: 32))

    func testNotchIsGapBetweenAuxiliaryAreas() {
        XCTAssertEqual(NotchGeometry.notchRect(builtIn), CGRect(x: 663.5, y: 950, width: 185, height: 32))
    }

    func testCollapsedPanelExtendsNotchSideways() {
        let f = NotchGeometry.collapsedFrame(builtIn)
        // 663.5 - 76 = 587.5 → 587; 848.5 + 76 = 924.5 → 925 (округление наружу).
        XCTAssertEqual(f, CGRect(x: 587, y: 950, width: 338, height: 32))
    }

    func testExpandedPanelHangsFromTopCenteredOnNotch() {
        let f = NotchGeometry.expandedFrame(builtIn)
        XCTAssertEqual(f.maxY, 982)
        XCTAssertEqual(f.midX, 756, accuracy: 0.5)
        XCTAssertEqual(f.size, NotchGeometry.expandedSize)
    }

    func testScreenWithoutNotchGetsPillUnderMenuBar() {
        let external = NotchScreen(frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
                                   visibleFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1055),
                                   safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        XCTAssertNil(NotchGeometry.notchRect(external))
        XCTAssertEqual(NotchGeometry.collapsedFrame(external),
                       CGRect(x: -960 - 100, y: 1255 - 26, width: 200, height: 26))
        XCTAssertEqual(NotchGeometry.expandedFrame(external).maxY, 1255)
    }

    func testAuxiliaryAreasRelativeToSecondaryScreenAreOffset() {
        var s = builtIn
        s.frame.origin = CGPoint(x: 1920, y: -300)
        s.visibleFrame.origin = CGPoint(x: 1920, y: -300)
        XCTAssertEqual(NotchGeometry.notchRect(s), CGRect(x: 1920 + 663.5, y: -300 + 950, width: 185, height: 32))
    }

    func testExpandedPanelStaysOnScreen() {
        let narrow = NotchScreen(frame: CGRect(x: 0, y: 0, width: 400, height: 600),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 575),
                                 safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        XCTAssertEqual(NotchGeometry.expandedFrame(narrow).minX, 0)
    }
}
