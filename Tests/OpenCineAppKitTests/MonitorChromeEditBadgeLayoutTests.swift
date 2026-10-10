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
}
