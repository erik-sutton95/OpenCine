#if os(iOS)
import MonitorPresentation
import XCTest

@testable import OpenCineAppKit

/// Inputs without an explicit count take the shared camera-value rule (three per
/// portrait phone row, so nine stills values make three rows).
@MainActor
final class MonitorCaptureColumnsTests: XCTestCase {
    private func inputs(_ count: Int, columns: Int? = nil) -> MonitorOperatorCaptureInputs<Int, String, Never> {
        .init(readouts: (0..<count).map { .init(id: $0, title: "V\($0)", value: "--") }, columns: columns,
            open: { _ in }, dismiss: {})
    }

    func testUnsetColumnsFollowTheSharedRule() {
        XCTAssertEqual(inputs(6).columns(portrait: true, tablet: false), 3)
        XCTAssertEqual(inputs(9).columns(portrait: true, tablet: false), 3)
        XCTAssertEqual(inputs(9).valueCount, 9)
        XCTAssertEqual(inputs(9).columns(portrait: false, tablet: false), 9)
        XCTAssertEqual(inputs(6).columns(portrait: true, tablet: true), 6)
    }

    func testAnExplicitCountWins() {
        XCTAssertEqual(inputs(9, columns: 2).columns(portrait: true, tablet: false), 2)
    }
}
#endif
