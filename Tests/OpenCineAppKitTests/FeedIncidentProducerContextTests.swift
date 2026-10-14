import Foundation
import OpenCineMedia
import XCTest

@testable import OpenCineAppKit

final class FeedIncidentProducerContextTests: XCTestCase {
    func testFactoryUsesSharedDeviceAndOriginalHostValues() {
        let device = DiagnosticsDevice(
            hardwareClass: "iPhone17,2", osName: "iOS", osVersion: "18.6.2")
        let context = FeedIncidentProducerContext(host: TestDiagnostics.host, device: device).make(
            sessionID: "session", cameraFamily: "test", decoderGeneration: 2, socketGeneration: 3,
            testSource: .automation, buildIdentity: "ios-source")
        XCTAssertEqual(context.hardwareClass, device.hardwareClass)
        XCTAssertEqual(context.osName, device.osName)
        XCTAssertEqual(context.osVersion, device.osVersion)
        XCTAssertEqual(context.appVersion, TestDiagnostics.host.version)
        XCTAssertEqual(context.appBuild, TestDiagnostics.host.build)
        XCTAssertEqual(context.sourceRevision, TestDiagnostics.host.sourceRevision)
        XCTAssertEqual(context.decoderGeneration, 2)
        XCTAssertEqual(context.socketGeneration, 3)
        XCTAssertEqual(context.testSource, .automation)
        XCTAssertEqual(context.buildIdentity, "ios-source")
        XCTAssertNil(context.cameraFirmware)
    }

    func testFactoryRetainsContextPrivacyAndBounds() {
        let context = FeedIncidentProducerContext(host: TestDiagnostics.host).make(
            sessionID: "session", cameraFamily: String(repeating: "x", count: 100),
            cameraFirmware: "SIMULATED-secret@example.invalid", decoderGeneration: -1)
        XCTAssertEqual(context.cameraFamily.count, 32)
        XCTAssertFalse(context.cameraFirmware?.contains("@") == true)
        XCTAssertEqual(context.decoderGeneration, 0)
    }
}
