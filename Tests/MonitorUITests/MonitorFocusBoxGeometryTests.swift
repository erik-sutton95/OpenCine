#if os(iOS)
    import MonitorUI
    import SwiftUI
    import XCTest

    /// Twin of the Compose MonitorFocusBoxGeometryTest: same cases, same numbers.
    final class MonitorFocusBoxGeometryTests: XCTestCase {
        private let feed = CGRect(x: 0, y: 0, width: 400, height: 200)

        private func mark(_ x: CGFloat, _ y: CGFloat, area: CGRect? = nil) -> MonitorFocusMark {
            MonitorFocusMark(point: CGPoint(x: x, y: y), color: .white, area: area)
        }

        private func assertFrame(
            _ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat,
            _ mark: MonitorFocusMark, line: UInt = #line
        ) {
            let frame = MonitorTrackingGeometry.focusBoxFrame(mark, in: feed)
            XCTAssertEqual(frame.minX, left, accuracy: 0.0001, line: line)
            XCTAssertEqual(frame.minY, top, accuracy: 0.0001, line: line)
            XCTAssertEqual(frame.maxX, right, accuracy: 0.0001, line: line)
            XCTAssertEqual(frame.maxY, bottom, accuracy: 0.0001, line: line)
        }

        func testTheStandardTapBoxIsASquareOfTheShortSideAroundThePoint() {
            assertFrame(186, 86, 214, 114, mark(0.5, 0.5))
        }

        func testACameraReportedAreaDrawsAtItsOwnSizeAndCentre() {
            assertFrame(
                100, 50, 300, 100,
                mark(0.9, 0.9, area: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25)))
        }

        func testAnEmptyReportedAreaFallsBackToTheStandardTapBox() {
            assertFrame(
                186, 86, 214, 114,
                mark(0.5, 0.5, area: CGRect(x: 0.25, y: 0.25, width: 0, height: 0.25)))
        }

        func testAReportedAreaKeepsItsOwnCornerUpToTheCapAndTheTapBoxKeepsSix() {
            let small = MonitorTrackingGeometry.focusBoxFrame(
                mark(0, 0, area: CGRect(x: 0, y: 0, width: 0.25, height: 0.2)), in: feed)
            XCTAssertEqual(
                MonitorTrackingGeometry.focusCornerRadius(for: small, reportedArea: true), 4.8,
                accuracy: 0.0001)
            let large = MonitorTrackingGeometry.focusBoxFrame(
                mark(0, 0, area: CGRect(x: 0, y: 0, width: 0.5, height: 1)), in: feed)
            XCTAssertEqual(
                MonitorTrackingGeometry.focusCornerRadius(for: large, reportedArea: true), 7,
                accuracy: 0.0001)
            let tap = MonitorTrackingGeometry.focusBoxFrame(mark(0.5, 0.5), in: feed)
            XCTAssertEqual(
                MonitorTrackingGeometry.focusCornerRadius(for: tap, reportedArea: false), 6,
                accuracy: 0.0001)
        }
    }
#endif
