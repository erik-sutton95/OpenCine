import Foundation
import XCTest

@testable import MonitorPresentation

final class MonitorScopeOptionsDecodingTests: XCTestCase {
    func testOptionsDecodeMissingKeysAsDefaults() throws {
        let empty = Data("{}".utf8)
        let decoder = JSONDecoder()

        let vector = try decoder.decode(MonitorVectorscopeOptions.self, from: empty)
        XCTAssertEqual(vector.zoom, .x1)
        XCTAssertEqual(vector.brightness, 100)
        XCTAssertEqual(vector.scale, 1)
        XCTAssertNil(vector.storedCenter)

        let wave = try decoder.decode(
            MonitorWaveformOptions.self, from: Data(#"{"brightness":150}"#.utf8))
        XCTAssertEqual(wave.mode, .rgb)
        XCTAssertEqual(wave.brightness, 150)
        XCTAssertEqual(wave.scale, 1)
        XCTAssertNil(wave.storedCenter)
        XCTAssertNil(wave.storedCenterPortrait)

        let parade = try decoder.decode(MonitorParadeOptions.self, from: empty)
        XCTAssertEqual(parade.mode, .rgb)
        XCTAssertEqual(parade.brightness, 100)
        XCTAssertEqual(parade.scale, 1)
        XCTAssertTrue(parade.guides.clip)
        XCTAssertNil(parade.storedCenter)

        let histogram = try decoder.decode(MonitorHistogramOptions.self, from: empty)
        var legacyDefaults = MonitorHistogramOptions.default
        legacyDefaults.hasCustomScale = true
        XCTAssertEqual(histogram, legacyDefaults)
        let scaled = try decoder.decode(
            MonitorHistogramOptions.self, from: Data(#"{"scale":0.7,"trafficLights":false}"#.utf8))
        XCTAssertEqual(scaled.scale, 0.7, accuracy: 1e-12)
        XCTAssertFalse(scaled.trafficLights)
        XCTAssertEqual(scaled.crushClipCompensation, .zero)
    }
}
