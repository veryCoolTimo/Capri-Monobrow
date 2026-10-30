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

    private let external = NotchScreen(
        frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 200, width: 1920, height: 1055),
        safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)

    func testNotchIsGapBetweenAuxiliaryAreas() {
        XCTAssertEqual(NotchGeometry.notchRect(builtIn), CGRect(x: 663.5, y: 950, width: 185, height: 32))
    }

    func testCollapsedShapeExtendsNotchSideways() {
        XCTAssertEqual(NotchGeometry.shapeRect(.collapsed, builtIn),
                       CGRect(x: 663.5 - 76, y: 950, width: 185 + 152, height: 32))
    }

    func testPeekIsOnlySlightlyBiggerThanCollapsed() {
        let collapsed = NotchGeometry.shapeRect(.collapsed, builtIn)
        let peek = NotchGeometry.shapeRect(.peek, builtIn)
        XCTAssertEqual(peek.maxY, 982)
        XCTAssertEqual(peek.midX, collapsed.midX)
        XCTAssertEqual(peek.height - collapsed.height, 34)
        XCTAssertEqual(peek.width - collapsed.width, 40)
    }

    func testExpandedHangsFromTopCenteredOnNotch() {
        let f = NotchGeometry.shapeRect(.expanded, builtIn)
        XCTAssertEqual(f.maxY, 982)
        XCTAssertEqual(f.midX, 756)
        XCTAssertEqual(f.size, CGSize(width: 400, height: 96))
    }

    func testExpandedAndAssistantHeightFollowContentWithinLimits() {
        XCTAssertEqual(NotchGeometry.shapeSize(.expanded, builtIn, contentHeight: 180).height, 180)
        XCTAssertEqual(NotchGeometry.shapeSize(.expanded, builtIn, contentHeight: 900).height, 300)
        XCTAssertEqual(NotchGeometry.shapeSize(.assistant, builtIn, contentHeight: 10).height, 150)
        let host = NotchGeometry.hostFrame(builtIn)
        XCTAssertTrue(host.contains(NotchGeometry.shapeRect(.assistant, builtIn, contentHeight: 900)))
    }

    func testHostPanelIsFixedAndContainsEveryState() {
        let host = NotchGeometry.hostFrame(builtIn)
        XCTAssertEqual(host.maxY, 982)
        for state in NotchState.allCases {
            XCTAssertTrue(host.contains(NotchGeometry.shapeRect(state, builtIn)), "\(state)")
        }
    }

    func testScreenWithoutNotchGrowsFromPillUnderMenuBar() {
        XCTAssertNil(NotchGeometry.notchRect(external))
        XCTAssertEqual(NotchGeometry.shapeRect(.collapsed, external),
                       CGRect(x: -960 - 100, y: 1255 - 26, width: 200, height: 26))
        XCTAssertEqual(NotchGeometry.shapeRect(.expanded, external).maxY, 1255)
        XCTAssertEqual(NotchGeometry.hostFrame(external).maxY, 1255)
    }

    func testAuxiliaryAreasRelativeToSecondaryScreenAreOffset() {
        var s = builtIn
        s.frame.origin = CGPoint(x: 1920, y: -300)
        s.visibleFrame.origin = CGPoint(x: 1920, y: -300)
        XCTAssertEqual(NotchGeometry.notchRect(s), CGRect(x: 1920 + 663.5, y: -300 + 950, width: 185, height: 32))
    }

    func testHostPanelStaysOnNarrowScreen() {
        let narrow = NotchScreen(frame: CGRect(x: 0, y: 0, width: 400, height: 600),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 575),
                                 safeAreaTop: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil)
        XCTAssertEqual(NotchGeometry.hostFrame(narrow).minX, 0)
    }
}
