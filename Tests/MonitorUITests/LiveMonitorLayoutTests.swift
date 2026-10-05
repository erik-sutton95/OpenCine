#if os(iOS)
    import MonitorUI
    import SwiftUI
    import XCTest

    /// Live chrome geometry helpers. Zone frames are `FieldMonitorLayout` (presentation tests).
    final class LiveMonitorLayoutTests: XCTestCase {
        func testChromeScaleFloorsCompactPhonesAndLeavesProMaxAlone() {
            XCTAssertEqual(LiveChromeMetrics.chromeScale(shortestSide: 360), 0.935, accuracy: 0.001)
            XCTAssertEqual(LiveChromeMetrics.chromeScale(shortestSide: 320), 0.935, accuracy: 0.001)
            XCTAssertEqual(LiveChromeMetrics.chromeScale(shortestSide: 424), 1, accuracy: 0.001)
            XCTAssertEqual(LiveChromeMetrics.chromeScale(shortestSide: 440), 1, accuracy: 0.001)
            XCTAssertEqual(
                LiveChromeMetrics.chromeScale(shortestSide: 410), 410 / 424, accuracy: 0.001)
        }

        /// Trailing island is a flush-left feed in standard space, not an extra
        /// in-arm mirror. Physical landscape-right then flips feed and chrome together.
        func testTrailingIslandMirrorsOnlyForDeviceLandscapeRight() {
            XCTAssertFalse(
                LiveMonitorLayout.shouldMirror(
                    leading: 0, trailing: 59, orientation: .landscapeLeft))
            XCTAssertTrue(
                LiveMonitorLayout.shouldMirror(
                    leading: 0, trailing: 59, orientation: .landscapeRight))
            XCTAssertTrue(
                LiveMonitorLayout.shouldMirror(
                    leading: 0, trailing: 59, orientation: .unknown))
        }

        /// Portrait GeometryReader is often the safe-area box. Width still matches
        /// the scene, so a width-only full-bleed test used to keep that short height
        /// and leave a dead band under the system bar / Operator Setup card.
        func testPortraitSafeAreaBoxUsesPhysicalScreenHeight() {
            let screen = CGSize(width: 390, height: 844)
            let inset = EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0)
            let fromInsetBox = LiveMonitorLayout.canvasSize(
                layoutSize: CGSize(width: 390, height: 751),
                safeArea: EdgeInsets(),
                screenSize: screen
            )
            XCTAssertEqual(fromInsetBox.width, 390, accuracy: 0.05)
            XCTAssertEqual(fromInsetBox.height, 844, accuracy: 0.05)

            let recovered = LiveMonitorLayout.resolvedSafeArea(EdgeInsets(), scene: inset)
            XCTAssertEqual(recovered.top, 59, accuracy: 0.05)
            XCTAssertEqual(recovered.bottom, 34, accuracy: 0.05)

            let canvas = LiveMonitorLayout.canvasSize(
                layoutSize: CGSize(width: 390, height: 844),
                safeArea: inset,
                screenSize: screen
            )
            XCTAssertEqual(canvas.height, 844, accuracy: 0.05)
            XCTAssertEqual(canvas.width, 390, accuracy: 0.05)
        }

        func testTopPickerAnchorsUnderChipLikeOpenZCine() {
            let viewport = CGSize(width: 874, height: 402)
            let cell = CGRect(x: 220, y: 14, width: 90, height: 34)
            let rec = LivePopupPlacement.topPicker(
                cell: cell,
                panelHeight: LiveChromeMetrics.drumPickerHeight
                    + LiveChromeMetrics.pickerModeBarHeight,
                viewport: viewport,
                safeArea: EdgeInsets()
            )
            let color = LivePopupPlacement.topPicker(
                cell: cell,
                panelHeight: LiveChromeMetrics.drumPickerHeight,
                viewport: viewport,
                safeArea: EdgeInsets()
            )
            XCTAssertEqual(rec.y, cell.maxY + 8, accuracy: 0.05)
            XCTAssertEqual(color.y, cell.maxY + 8, accuracy: 0.05)
            XCTAssertGreaterThan(
                rec.maxHeight,
                LiveChromeMetrics.drumPickerHeight + LiveChromeMetrics.pickerModeBarHeight
            )
        }
    }
#endif
