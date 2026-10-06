#if os(iOS)
    import MonitorPresentation
    import OpenCineCameraVocabulary
    import SwiftUI
    import XCTest

    @testable import OpenCineCameraControls

    final class LiveChromeTests: XCTestCase {
        func testLongPressEnabledForRemainingTools() {
            let tapOnly: Set<MonitorAssistSelection> = [.evMeter, .level]
            for tool in MonitorAssistSelection.settingsCases where !tapOnly.contains(tool) {
                XCTAssertTrue(tool.hasConfiguration, "\(tool.rawValue) should open options")
            }
            // Audio has local presentation options; mirror picks its flip axes.
            XCTAssertTrue(MonitorAssistSelection.audioMeters.hasConfiguration)
            XCTAssertTrue(MonitorAssistSelection.mirror.hasConfiguration)
            XCTAssertFalse(MonitorAssistSelection.level.hasConfiguration)
            XCTAssertTrue(MonitorAssistSelection.desqueeze.hasConfiguration)
        }

        func testFPSHoldIgnoresHundredthTick() {
            XCTAssertEqual(LiveChromeReadout.holdFPS("25.13", displayed: "25.00"), "25.00")
            XCTAssertEqual(LiveChromeReadout.holdFPS("24.70", displayed: "25.00"), "25.00")
            XCTAssertEqual(LiveChromeReadout.holdFPS("25.50", displayed: "25.00"), "25.50")
            XCTAssertEqual(LiveChromeReadout.holdFPS("RECOV", displayed: "25.00"), "RECOV")
            XCTAssertEqual(LiveChromeReadout.holdFPS("25.00", displayed: "LINK"), "25.00")
            XCTAssertEqual(LiveChromeReadout.holdFPS("\u{2014}", displayed: "25.00"), "\u{2014}")
        }

        func testPaddingMatchesTheZcTapTargetMinimumWithoutGrowingLargerControls() {
            XCTAssertEqual(MonitorReadoutHitTarget.minimumSize, 44)
            XCTAssertEqual(
                MonitorReadoutHitTarget.padding(for: .zero), .zero,
                "Unmeasured labels must not pad on the first layout pass")
            XCTAssertEqual(
                MonitorReadoutHitTarget.padding(for: CGSize(width: 40, height: 16)),
                CGSize(width: 2, height: 14))
            XCTAssertEqual(
                MonitorReadoutHitTarget.padding(for: CGSize(width: 78, height: 12)),
                CGSize(width: 0, height: 16),
                "Portrait REC SETUP stays intrinsically wide and only grows the 44pt height")
            XCTAssertEqual(
                MonitorReadoutHitTarget.padding(for: CGSize(width: 52, height: 19)),
                CGSize(width: 0, height: 12.5),
                "Landscape FORMAT/COLOR/MODE keep their glyph width")
            XCTAssertEqual(
                MonitorReadoutHitTarget.padding(for: CGSize(width: 80, height: 50)), .zero)
            XCTAssertEqual(
                MonitorReadoutHitTarget.padding(for: CGSize(width: 44, height: 44)), .zero)
        }

        func testFocusEditRectUsesTrackedBoxAndFallsBackToAFPoint() {
            let feed = CGRect(x: 0, y: 0, width: 1600, height: 900)
            let box = TrackingBox(x: 0.25, y: 0.2, width: 0.2, height: 0.3)
            let tracked = LiveChromeEditGeometry.focusEditRect(
                overlay: .face(box),
                faces: [],
                focusPoint: CGPoint(x: 0.5, y: 0.5),
                mirrored: false,
                in: feed
            )
            XCTAssertEqual(tracked.minX, 400, accuracy: 0.5)
            XCTAssertEqual(tracked.minY, 180, accuracy: 0.5)
            XCTAssertEqual(tracked.width, 320, accuracy: 0.5)
            XCTAssertEqual(tracked.height, 270, accuracy: 0.5)

            let fallback = LiveChromeEditGeometry.focusEditRect(
                overlay: .focus,
                faces: [],
                focusPoint: CGPoint(x: 0.5, y: 0.5),
                mirrored: false,
                in: feed
            )
            XCTAssertEqual(fallback.midX, 800, accuracy: 0.5)
            XCTAssertEqual(fallback.midY, 450, accuracy: 0.5)
            XCTAssertEqual(fallback.width, fallback.height, accuracy: 0.5)
        }
    }
#endif
