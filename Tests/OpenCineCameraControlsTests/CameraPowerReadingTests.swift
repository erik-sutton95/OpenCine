#if os(iOS)
    import OpenCineCore
    import XCTest

    @testable import OpenCineCameraControls

    /// Kotlin twin: `CameraPowerReadingTest`. Every live entry (the descriptor scene and app sources)
    /// shows the camera battery at the precision its source declared.
    final class CameraPowerReadingTests: XCTestCase {
        private func power(_ value: Double?, _ precision: ObservationPrecision?, charging: Bool? = nil) -> PowerStatus {
            PowerStatus(
                battery: value.map { ObservedValue($0, origin: .cameraReported, at: nil, precision: precision) } ?? .unknown,
                charging: charging.map { ObservedValue($0, origin: .cameraReported, at: nil) } ?? .unknown)
        }

        func testAFiveStepGaugeKeepsItsBarsAndNeverReadsAsAPercentage() throws {
            let reading = try XCTUnwrap(MonitorOperatorPowerReading.camera(power(0.6, .quantized(step: 0.2))))
            XCTAssertEqual(reading.bars, 3)
            XCTAssertEqual(reading.barCount, 5)
            XCTAssertNil(reading.percent)
            XCTAssertFalse(reading.warning)
            XCTAssertTrue(try XCTUnwrap(MonitorOperatorPowerReading.camera(power(0.4, .quantized(step: 0.2)))).warning)
        }

        func testAFractionPrintsAPercentageAndUnknownIsAbsent() throws {
            let reading = try XCTUnwrap(MonitorOperatorPowerReading.camera(power(0.6, .quantized(step: 0.01), charging: true)))
            XCTAssertEqual(reading.percent, 60)
            XCTAssertNil(reading.bars)
            XCTAssertEqual(reading.charging, true)
            XCTAssertNil(MonitorOperatorPowerReading.camera(power(nil, .quantized(step: 0.2))))
        }
    }
#endif
