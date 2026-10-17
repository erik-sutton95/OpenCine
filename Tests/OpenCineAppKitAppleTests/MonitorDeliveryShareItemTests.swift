#if os(iOS)
import OpenCineAppKitApple
import UIKit
import UniformTypeIdentifiers
import XCTest

/// SIMULATED gyro sidecar and movie URLs use the same native provider as delivery.
@MainActor final class MonitorDeliveryShareItemTests: XCTestCase {
    func testMotionSidecarKeepsItsDataTypeAndFilename() throws {
        let item = MonitorDeliveryShareItem(fileURL: URL(fileURLWithPath: "/SIMULATED/take.gcsv"), contentType: .data)
        let controller = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewController(controller, dataTypeIdentifierForActivityType: nil), UTType.data.identifier)
        let provider = try XCTUnwrap(item.activityViewControllerPlaceholderItem(controller) as? NSItemProvider)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
        XCTAssertEqual(provider.suggestedName, "take.gcsv")
        let movie = MonitorDeliveryShareItem(fileURL: URL(fileURLWithPath: "/SIMULATED/take.mov"))
        XCTAssertEqual(movie.activityViewController(controller, dataTypeIdentifierForActivityType: nil), UTType.quickTimeMovie.identifier)
    }
}
#endif
