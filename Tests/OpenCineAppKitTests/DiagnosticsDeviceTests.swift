import Foundation
import OpenCineAppKit
import XCTest

final class DiagnosticsDeviceTests: XCTestCase {
    func testTheSimulatorNamesTheDeviceItModels() {
        XCTAssertEqual(
            DiagnosticsDevice.machineIdentifier(environment: [
                "SIMULATOR_MODEL_IDENTIFIER": "iPhone17,2"
            ]),
            "iPhone17,2")
        XCTAssertFalse(DiagnosticsDevice.machineIdentifier(environment: [:]).isEmpty)
    }

    func testTheVersionReadsLikeTheSystemVersion() {
        XCTAssertEqual(
            DiagnosticsDevice.version(.init(majorVersion: 26, minorVersion: 2, patchVersion: 0)),
            "26.2")
        XCTAssertEqual(
            DiagnosticsDevice.version(.init(majorVersion: 18, minorVersion: 6, patchVersion: 2)),
            "18.6.2")
    }
}
