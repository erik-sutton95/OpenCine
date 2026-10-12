#if os(iOS)
import Foundation
import OpenCineAppKitApple
import XCTest

/// A2-06: a cached still is delivered as its original file; the video allowlist dropped it.
final class MonitorDeliveryShareStagingTests: XCTestCase {
    func testStillAndMovieOriginalsBothReachTheShareSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-share-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let still = root.appendingPathComponent("SIMULATED_0001.JPG")
        let movie = root.appendingPathComponent("SIMULATED_0002.MOV")
        let sidecar = root.appendingPathComponent("SIMULATED_0002.json")
        for url in [still, movie, sidecar] { try Data([1, 2, 3]).write(to: url) }
        let staged = try MonitorDeliveryShareStaging.prepareForShare(urls: [still, movie, sidecar])
        XCTAssertEqual(staged.urls, [still, movie])
        XCTAssertNil(staged.stagingCleanupURL)
    }
}
#endif
