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

        func testIndependentExhaustionAndUnknownRemainTruthful() throws {
            for exhausted in [nil, false, true] as [Bool?] {
                let reading = try XCTUnwrap(MonitorOperatorPowerReading.camera(.steps(filled: 1, of: 4), exhausted: exhausted))
                XCTAssertEqual(reading.bars, 1)
                XCTAssertEqual(reading.barCount, 4)
                XCTAssertEqual(reading.exhausted, exhausted == true)
                XCTAssertNil(reading.charging)
                XCTAssertEqual(MonitorOperatorPowerReading.readoutLabel(.steps(filled: 1, of: 4)), "1/4")
            }
            XCTAssertEqual(MonitorOperatorPowerReading.readoutLabel(.fraction(0)), "0%")
            XCTAssertNil(MonitorOperatorPowerReading.camera(nil as BatteryReading?))
            XCTAssertNil(MonitorOperatorPowerReading.camera(.fraction(.nan)))
            XCTAssertNil(MonitorOperatorPowerReading.camera(.steps(filled: 1, of: 0)))
            XCTAssertFalse(try XCTUnwrap(MonitorOperatorPowerReading.camera(.steps(filled: Int.max, of: Int.max))).warning)
            let external = PowerStatus(battery: .init(0.68, origin: .cameraReported, at: nil),
                externalPower: .init(true, origin: .cameraReported, at: nil))
            XCTAssertEqual(MonitorOperatorPowerReading.camera(external)?.charging, true)
        }

        /// Behavior audit ZAA-304: a body on external power with no level keeps its pill (EXT).
        func testExternalPowerWithoutALevelKeepsThePill() throws {
            let reading = try XCTUnwrap(MonitorOperatorPowerReading.camera(PowerStatus(
                externalPower: .init(true, origin: .cameraReported, at: nil))))
            XCTAssertNil(reading.percent)
            XCTAssertNil(reading.bars)
            XCTAssertEqual(reading.externalPower, true)
            XCTAssertEqual(reading.charging, true)
            XCTAssertTrue(try XCTUnwrap(MonitorOperatorPowerReading.camera(PowerStatus(
                externalPower: .init(true, origin: .cameraReported, at: nil),
                exhausted: .init(true, origin: .cameraReported, at: nil)))).exhausted)
            XCTAssertNil(MonitorOperatorPowerReading.camera(PowerStatus(
                externalPower: .init(false, origin: .cameraReported, at: nil))))
            XCTAssertNil(MonitorOperatorPowerReading.camera(PowerStatus.unknown))
            let gauge = try XCTUnwrap(MonitorOperatorPowerReading.camera(PowerStatus(
                battery: .init(0.6, origin: .cameraReported, at: nil, precision: .quantized(step: 0.2)),
                externalPower: .init(true, origin: .cameraReported, at: nil))))
            XCTAssertEqual(gauge.bars, 3)
            XCTAssertEqual(gauge.externalPower, true)
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
