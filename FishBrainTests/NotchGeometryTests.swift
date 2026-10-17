import AppKit
import XCTest

final class NotchGeometryTests: XCTestCase {
    /// This Mac's built-in display, as measured: 1710x1107 points with a 185-point-wide notch.
    private let notchedBuiltIn = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1710, height: 1107),
        visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073.5),
        safeAreaTop: 33.5,
        auxiliaryTopLeft: CGRect(x: 0, y: 1073.5, width: 762.5, height: 33.5),
        auxiliaryTopRight: CGRect(x: 947.5, y: 1073.5, width: 762.5, height: 33.5)
    )

    private let plainExternal = ScreenMetrics(
        frame: CGRect(x: 1710, y: -200, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1710, y: -200, width: 2560, height: 1415), // 25 pt menu bar
        safeAreaTop: 0,
        auxiliaryTopLeft: nil,
        auxiliaryTopRight: nil
    )

    // MARK: Notched Macs

    func testTheNotchIsTheGapBetweenTheTwoMenuBarStrips() {
        let p = NotchGeometry.placement(for: notchedBuiltIn)
        XCTAssertTrue(p.hasNotch)
        XCTAssertEqual(p.notchFrame, CGRect(x: 762.5, y: 1073.5, width: 185, height: 33.5))
        XCTAssertEqual(p.notchFrame.midX, notchedBuiltIn.frame.midX, "the notch is centered")
        XCTAssertEqual(p.notchFrame.maxY, notchedBuiltIn.frame.maxY, "flush with the top of the display")
    }

    func testTheCollapsedPanelWrapsTheNotchWithAWingEitherSide() {
        let p = NotchGeometry.placement(for: notchedBuiltIn)
        let frame = p.collapsedFrame()
        XCTAssertEqual(frame.width, 185 + 2 * NotchGeometry.collapsedWing)
        XCTAssertEqual(frame.height, 33.5)
        XCTAssertEqual(frame.midX, p.notchFrame.midX)
        XCTAssertEqual(frame.maxY, notchedBuiltIn.frame.maxY)
    }

    func testAnExpandedPanelStaysCenteredOnTheNotchAndFlushWithTheTop() {
        let p = NotchGeometry.placement(for: notchedBuiltIn)
        let frame = p.frame(size: CGSize(width: 420, height: 222))
        XCTAssertEqual(frame.midX, p.notchFrame.midX)
        XCTAssertEqual(frame.maxY, notchedBuiltIn.frame.maxY)
        XCTAssertEqual(frame.size, CGSize(width: 420, height: 222))
    }

    func testANotchedDisplayThatIsNotAtTheOriginIsPlacedByItsOwnCoordinates() {
        var moved = notchedBuiltIn
        moved.frame.origin = CGPoint(x: -1710, y: 300)
        moved.auxiliaryTopLeft?.origin = CGPoint(x: -1710, y: 300 + 1073.5)
        moved.auxiliaryTopRight?.origin = CGPoint(x: -1710 + 947.5, y: 300 + 1073.5)

        let p = NotchGeometry.placement(for: moved)
        XCTAssertEqual(p.notchFrame, CGRect(x: -1710 + 762.5, y: 300 + 1073.5, width: 185, height: 33.5))
    }

    func testANotchWithoutMeasurableStripsFallsBackToACenteredDefaultWidth() {
        var m = notchedBuiltIn
        m.auxiliaryTopLeft = nil
        m.auxiliaryTopRight = nil
        let p = NotchGeometry.placement(for: m)
        XCTAssertTrue(p.hasNotch)
        XCTAssertEqual(p.notchFrame.width, NotchGeometry.fallbackNotchWidth)
        XCTAssertEqual(p.notchFrame.height, 33.5)
        XCTAssertEqual(p.notchFrame.midX, m.frame.midX)
    }

    func testNonsenseStripsAreIgnored() {
        var m = notchedBuiltIn
        m.auxiliaryTopRight = CGRect(x: 100, y: 1073.5, width: 50, height: 33.5) // starts left of the left strip's end
        XCTAssertEqual(NotchGeometry.placement(for: m).notchFrame.width, NotchGeometry.fallbackNotchWidth)
    }

    func testTheAlignedPanelIsOnWholePointsAndNeverPokesBelowTheMenuBar() {
        let p = NotchGeometry.placement(for: notchedBuiltIn)
        let aligned = p.alignedCollapsedFrame()
        XCTAssertEqual(aligned, CGRect(x: 729, y: 1074, width: 253, height: 33))
        XCTAssertLessThanOrEqual(aligned.height, p.notchFrame.height, "rounded down, not up")
        XCTAssertEqual(aligned.maxY, notchedBuiltIn.frame.maxY, "still flush with the top")
        XCTAssertEqual(aligned.midX, notchedBuiltIn.frame.midX, accuracy: 0.5, "still centered to within half a point")
    }

    func testAlignmentLeavesAnAlreadyWholeFrameAlone() {
        let p = NotchGeometry.placement(for: plainExternal) // 25 pt tall, 200 pt wide
        let aligned = p.alignedCollapsedFrame(wing: 34)
        XCTAssertEqual(aligned.height, 25)
        XCTAssertEqual(aligned.width, 268)
    }

    // MARK: Macs without a notch

    func testWithoutANotchThePanelSitsCenteredInTheMenuBar() {
        let p = NotchGeometry.placement(for: plainExternal)
        XCTAssertFalse(p.hasNotch)
        XCTAssertEqual(p.notchFrame.height, 25, "menu bar height, measured from the visible frame")
        XCTAssertEqual(p.notchFrame.width, NotchGeometry.fallbackNotchWidth)
        XCTAssertEqual(p.notchFrame.midX, plainExternal.frame.midX)
        XCTAssertEqual(p.notchFrame.maxY, plainExternal.frame.maxY)
    }

    func testAHiddenMenuBarFallsBackToADefaultHeight() {
        var m = plainExternal
        m.visibleFrame = m.frame // nothing reserved for the menu bar
        XCTAssertEqual(NotchGeometry.placement(for: m).notchFrame.height, NotchGeometry.fallbackMenuBarHeight)
    }

    func testTheCollapsedPanelOnAPlainDisplayIsMenuBarHighAndCentered() {
        let frame = NotchGeometry.placement(for: plainExternal).collapsedFrame()
        XCTAssertEqual(frame.height, 25)
        XCTAssertEqual(frame.midX, plainExternal.frame.midX)
        XCTAssertEqual(frame.maxY, plainExternal.frame.maxY)
    }

    // MARK: Choosing the display

    func testThePanelGoesOnTheNotchedDisplayEvenWhenItIsNotFirst() {
        XCTAssertEqual(NotchGeometry.chooseScreen([plainExternal, notchedBuiltIn]), 1)
        XCTAssertEqual(NotchGeometry.chooseScreen([notchedBuiltIn, plainExternal]), 0)
    }

    func testWithoutANotchThePrimaryDisplayIsUsed() {
        XCTAssertEqual(NotchGeometry.chooseScreen([plainExternal]), 0)
        XCTAssertEqual(NotchGeometry.chooseScreen([plainExternal, plainExternal]), 0)
    }

    func testNoDisplaysMeansNoPlacement() {
        XCTAssertNil(NotchGeometry.chooseScreen([]))
    }

    // MARK: Display changes

    func testPlugInAMonitorAndTheNotchStaysPut() {
        let alone = NotchGeometry.chooseScreen([notchedBuiltIn]).map { NotchGeometry.placement(for: [notchedBuiltIn][$0]) }
        let withMonitor = NotchGeometry.chooseScreen([notchedBuiltIn, plainExternal]).map { NotchGeometry.placement(for: [notchedBuiltIn, plainExternal][$0]) }
        XCTAssertEqual(alone, withMonitor)
    }

    func testUnplugTheNotchedDisplayAndThePanelMovesToTheMonitorMenuBar() {
        let before = NotchGeometry.chooseScreen([notchedBuiltIn, plainExternal]).map { [notchedBuiltIn, plainExternal][$0] }
        let after = NotchGeometry.chooseScreen([plainExternal]).map { [plainExternal][$0] }
        XCTAssertEqual(before, notchedBuiltIn)
        XCTAssertEqual(after, plainExternal)
        XCTAssertEqual(NotchGeometry.placement(for: after!).notchFrame.midX, plainExternal.frame.midX)
    }

    func testAResolutionChangeMovesTheNotch() {
        var scaled = notchedBuiltIn
        scaled.frame.size = CGSize(width: 1512, height: 982)
        scaled.visibleFrame.size = CGSize(width: 1512, height: 948.5)
        scaled.auxiliaryTopLeft = CGRect(x: 0, y: 948.5, width: 663.5, height: 33.5)
        scaled.auxiliaryTopRight = CGRect(x: 848.5, y: 948.5, width: 663.5, height: 33.5)

        let p = NotchGeometry.placement(for: scaled)
        XCTAssertEqual(p.notchFrame.midX, 756)
        XCTAssertEqual(p.notchFrame.maxY, 982)
    }
}

@MainActor
final class NotchPanelTests: XCTestCase {
    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        addTeardownBlock { panel.orderOut(nil) }
        return panel
    }

    func testItIsBorderlessTransparentAndShadowless() {
        let panel = makePanel()
        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.backgroundColor, .clear)
        XCTAssertFalse(panel.hasShadow)
    }

    func testItSitsAboveTheMenuBar() {
        XCTAssertGreaterThan(makePanel().level.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    func testItIsOnEverySpaceAndOverFullScreenApps() {
        let behavior = makePanel().collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertTrue(behavior.contains(.ignoresCycle), "stays out of Cmd-Tab and window cycling")
    }

    func testItNeverTakesFocus() {
        let panel = makePanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)

        // Shown without activating, it still isn't key or main.
        panel.setFrame(CGRect(x: -20_000, y: -20_000, width: 253, height: 33), display: false)
        panel.orderFrontRegardless()
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.isMainWindow)
    }

    func testItCannotBeDraggedAway() {
        XCTAssertFalse(makePanel().isMovable)
    }
}

