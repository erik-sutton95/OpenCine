import Foundation
import OpenCineAppKit
import XCTest

/// Edit view eye badges: on the control, toward the canvas centre, inside the corner inset.
final class MonitorChromeEditBadgeLayoutTests: XCTestCase {
    func testBadgeFramesSitOnTopBarAndAvoidOverlap() throws {
        let statusBox = CGRect(x: 120, y: 12, width: 420, height: 40)
        let recBox = CGRect(x: 128, y: 16, width: 72, height: 32)
        let viewport = CGSize(width: 874, height: 402)
        let frames = MonitorChromeEditBadgeLayout.badgeFrames(
            [
                .init(section: .statusBar, frame: statusBox),
                .init(section: .recReadout, frame: recBox),
            ],
            viewport: viewport
        )

        let status = try XCTUnwrap(frames[.statusBar])
        let rec = try XCTUnwrap(frames[.recReadout])
        let playable = MonitorChromeEditBadgeLayout.playableRect(in: viewport)
        XCTAssertTrue(playable.contains(status))
        XCTAssertTrue(playable.contains(rec))
        // Top-deck eyes sit on the bar, not on the physical top edge.
        XCTAssertGreaterThan(status.minY, MonitorChromeEditBadgeLayout.edgeInset - 0.5)
        XCTAssertTrue(statusBox.intersects(status))
        XCTAssertGreaterThan(status.midY, statusBox.midY - 1)
        XCTAssertGreaterThan(abs(status.midX - rec.midX) + abs(status.midY - rec.midY), 20)
        XCTAssertFalse(
            status.insetBy(
                dx: -MonitorChromeEditBadgeLayout.badgeGap,
                dy: -MonitorChromeEditBadgeLayout.badgeGap
            )
            .intersects(rec)
        )
    }

    func testBadgeFramesPullInwardFromTrailingRail() throws {
        let viewport = CGSize(width: 874, height: 402)
        let settings = CGRect(x: 792, y: 14, width: 64, height: 64)
        let frames = MonitorChromeEditBadgeLayout.badgeFrames(
            [.init(section: .railSettings, frame: settings)],
            viewport: viewport
        )
        let badge = try XCTUnwrap(frames[.railSettings])
        let playable = MonitorChromeEditBadgeLayout.playableRect(in: viewport)
        XCTAssertTrue(playable.contains(badge))
        XCTAssertLessThanOrEqual(
            badge.maxX, viewport.width - MonitorChromeEditBadgeLayout.edgeInset + 0.5)
        XCTAssertTrue(settings.intersects(badge))
        // Right-rail control: eye on the leading (inward) side.
        XCTAssertLessThan(badge.midX, settings.midX)
    }

    func testBadgeFramesPullInwardFromLeadingGutter() throws {
        let viewport = CGSize(width: 874, height: 402)
        let lock = CGRect(x: 16, y: 14, width: 40, height: 40)
        let frames = MonitorChromeEditBadgeLayout.badgeFrames(
            [.init(section: .lockButton, frame: lock)],
            viewport: viewport
        )
        let badge = try XCTUnwrap(frames[.lockButton])
        let playable = MonitorChromeEditBadgeLayout.playableRect(in: viewport)
        XCTAssertTrue(playable.contains(badge))
        XCTAssertGreaterThanOrEqual(badge.minX, MonitorChromeEditBadgeLayout.edgeInset - 0.5)
        XCTAssertTrue(lock.intersects(badge))
        // Left-gutter control: eye on the trailing (inward) side.
        XCTAssertGreaterThan(badge.midX, lock.midX)
    }

    /// One table for both twins (Kotlin: `MonitorChromeEditBadgeLayoutTest.placementTable`):
    /// each case lists its boxes in placement order, the badges' touch target, and the exact
    /// badge origin every placed box gets; a box missing from `expected` gets no badge.
    /// Measured cases are the boxes a staged review logged.
    private struct Case {
        let name: String
        let viewport: CGSize
        let touchTarget: CGFloat
        let boxes: [(key: String, frame: CGRect)]
        let expected: [(key: String, x: CGFloat, y: CGFloat)]
    }

    private static func box(_ key: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat)
        -> (key: String, frame: CGRect)
    {
        (key, CGRect(x: x, y: y, width: w, height: h))
    }

    private static let placementTable: [Case] = [
        // Measured: iOS 852x393 landscape (the boxes Z RunnerTests pins); iOS S4 runs portrait
        // only.
        Case(
            name: "iosPhoneLandscape", viewport: CGSize(width: 852, height: 393), touchTarget: 44,
            boxes: [
                box("statusBar", 69, 16, 678, 42),
                box("railSettings", 763, 14, 83, 289),
                box("toolBar", 16, 321, 344, 58),
                box("cameraValues", 368, 321, 466, 58),
                box("lockButton", 16, 17, 40, 40),
                box("batteries", 8, 63, 41, 35),
                box("recReadout", 81, 23, 67, 27),
                box("codec", 377, 22, 98, 30),
                box("storage", 485, 22, 132, 30),
                box("fps", 627, 22, 108, 29),
            ],
            expected: [
                ("statusBar", 725, 36),
                ("railSettings", 759, 281),
                ("toolBar", 338, 317),
                ("cameraValues", 588, 317),
                ("lockButton", 34, 35),
                ("batteries", 27, 79),
                ("recReadout", 126, 28),
                ("codec", 373, 30),
                ("storage", 481, 30),
                ("fps", 623, 29),
            ]),
        // Synthetic: b collides on every anchor and slides out to the nearest free spot; c and
        // inner are nested in bar, whose eye leaves them none, so they get no badge.
        Case(
            name: "crowdedStacksOutwardAndDropsNested", viewport: CGSize(width: 800, height: 400),
            touchTarget: 44,
            boxes: [
                box("a", 100, 100, 30, 30),
                box("b", 100, 100, 30, 30),
                box("bar", 400, 90, 200, 50),
                box("c", 420, 100, 30, 30),
                box("inner", 420, 100, 30, 30),
            ],
            expected: [
                ("a", 108, 108),
                ("b", 108, 152),
                ("bar", 396, 118),
            ]),
        // Measured: Pocket and Insta phone landscape (identical boxes; runs pocket-s4-phone-07,
        // insta-s4-phone-04).
        Case(
            name: "androidPhoneLandscape", viewport: CGSize(width: 914.286, height: 411.429),
            touchTarget: 48,
            boxes: [
                box("LOCK_BUTTON", 12.19, 12.19, 48, 48),
                box("BATTERIES", 12.19, 72.381, 57.905, 68.19),
                box("STATUS_BAR", 103.619, 0, 733.714, 44.19),
                box("TOOL_BAR", 12.19, 297.524, 89.143, 110.095),
                box("CAMERA_VALUES", 112, 372.952, 690.286, 34.667),
                box("RAIL_RECORD", 838.476, 333.333, 70.095, 70.095),
                box("RAIL_MEDIA", 849.143, 72.381, 48, 48),
                box("RAIL_SETTINGS", 849.143, 12.19, 48, 48),
                box("REC_READOUT", 670.095, 11.81, 53.333, 20.571),
                box("TIMECODE", 733.333, 8, 77.714, 28.19),
                box("FORMAT", 160.381, 12.571, 38.476, 19.429),
                box("COLOR", 222.857, 12.571, 13.714, 19.429),
                box("STORAGE", 103.619, 12.571, 32.762, 19.429),
            ],
            expected: [
                ("LOCK_BUTTON", 38.19, 38.19),
                ("BATTERIES", 48.095, 118.571),
                ("STATUS_BAR", 99.619, 22.19),
                ("TOOL_BAR", 79.333, 293.524),
                ("CAMERA_VALUES", 108, 368.952),
                ("RAIL_RECORD", 834.476, 329.333),
                ("RAIL_MEDIA", 845.143, 98.381),
                ("RAIL_SETTINGS", 845.143, 38.19),
                ("REC_READOUT", 666.095, 16),
                ("TIMECODE", 729.333, 16),
                ("FORMAT", 176.857, 16),
            ]),
        // Measured: Pocket and Insta tablet portrait (identical boxes; runs pocket-s4-tablet-07,
        // insta-s4-tablet-04).
        Case(
            name: "androidTabletPortrait", viewport: CGSize(width: 800, height: 1280),
            touchTarget: 48,
            boxes: [
                box("LOCK_BUTTON", 8, 1198, 48, 48),
                box("BATTERIES", 8, 82, 58, 68),
                box("STATUS_BAR", 8, 0, 772, 52),
                box("TOOL_BAR", 8, 1006, 56, 83),
                box("CAMERA_VALUES", 14, 1122.5, 772, 37.5),
                box("RAIL_RECORD", 358, 1180, 84, 84),
                box("RAIL_MEDIA", 684, 1198, 48, 48),
                box("RAIL_SETTINGS", 744, 1198, 48, 48),
                box("REC_READOUT", 8, 0, 53.5, 20.5),
                box("TIMECODE", 350, 0, 88, 31.5),
                box("COLOR", 732, 0, 48, 48),
                box("STORAGE", 8, 52, 35.5, 22.5),
            ],
            expected: [
                ("LOCK_BUTTON", 34, 1194),
                ("BATTERIES", 44, 128),
                ("STATUS_BAR", 758, 30),
                ("TOOL_BAR", 42, 1002),
                ("CAMERA_VALUES", 16, 1118.5),
                ("RAIL_RECORD", 354, 1176),
                ("RAIL_MEDIA", 680, 1194),
                ("RAIL_SETTINGS", 740, 1194),
                ("REC_READOUT", 39.5, 16),
                ("TIMECODE", 416, 16),
                ("STORAGE", 21.5, 64),
            ]),
    ]

    func testPlacementTableMatchesTheKotlinTwin() {
        let size = MonitorChromeEditBadgeLayout.badgeSize
        for testCase in Self.placementTable {
            let placed = MonitorChromeEditBadgeLayout.badgeFrames(
                keyed: testCase.boxes, viewport: testCase.viewport,
                touchTarget: testCase.touchTarget)
            XCTAssertEqual(
                Set(placed.keys), Set(testCase.expected.map(\.key)),
                "\(testCase.name): badged boxes")
            for want in testCase.expected {
                guard let frame = placed[want.key] else { continue }
                XCTAssertEqual(frame.minX, want.x, accuracy: 0.01, "\(testCase.name) \(want.key) x")
                XCTAssertEqual(frame.minY, want.y, accuracy: 0.01, "\(testCase.name) \(want.key) y")
                XCTAssertEqual(
                    frame.size, CGSize(width: size, height: size), "\(testCase.name) \(want.key)")
            }
            // No two badges' touch targets (or discs) overlap.
            let reach = max(size, testCase.touchTarget)
            let frames = Array(placed.values)
            for i in frames.indices {
                for j in frames.indices where j > i {
                    XCTAssertTrue(
                        abs(frames[i].minX - frames[j].minX) >= reach
                            || abs(frames[i].minY - frames[j].minY) >= reach,
                        "\(testCase.name): badges overlap")
                }
            }
        }
    }
}
