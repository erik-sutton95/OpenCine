import OpenCineCameraVocabulary
import OpenCineDJI
import OpenCineMedia
import Testing

// Draft only. Retains the exact original function type, named parameters, counts and scalar values.
struct MonitorFeedEffectsWireStatelessCompatibilityTests {
    @Test func originalFunctionReferencesAndInvalidOrdinalsRemainAvailable() {
        let paint: (Int, Int, Int, MonitorColorSourceProfile) -> [UInt8]? =
            MonitorFeedEffectsWire.packedFalseColorPaint
        let weight: (Int, Int, Int, MonitorColorSourceProfile) -> [UInt8]? =
            MonitorFeedEffectsWire.packedFalseColorWeight
        #expect(paint(-1, 0, 800, DJIMonitorColorProfile.value) == nil)
        #expect(weight(8, 0, 800, DJIMonitorColorProfile.value) == nil)
        #expect(MonitorFeedEffectsWire.falseColorCubeSize == 64)
        #expect(MonitorFeedEffectsWire.assistScalarCount == 4)
    }

    @Test func fullPayloadEqualitySurvivesInterleavingProfilesAndEscapedValueMutation() throws {
        let source = DJIMonitorColorProfile.value
        let first = try #require(MonitorFeedEffectsWire.packedFalseColorPaint(
            scaleOrdinal: 1, colorModeCode: 0, iso: 800, sourceProfile: source))
        #expect(first.count == 1_048_576)
        var borrowed = first
        borrowed[52] ^= 0xff
        // Another owner's source facts stay explicit; there is no process calibration owner.
        _ = MonitorFeedEffectsWire.assistScalars(colorModeCode: 0, iso: 800,
            highlightIRE: 95, midtoneIRE: 42, sourceProfile: .init())
        let again = try #require(MonitorFeedEffectsWire.packedFalseColorPaint(
            scaleOrdinal: 1, colorModeCode: 0, iso: 800, sourceProfile: source))
        #expect(first == again)
        #expect(borrowed != again)
    }

    /// A source whose colour identity is not a mode byte names its curve; the payload matches
    /// the byte that names the same curve.
    @Test func namedCurvesProduceTheSamePayloadsAsTheirModeByte() throws {
        let source = DJIMonitorColorProfile.value
        let code = Int(ColorMode.dLog2.rawValue)
        let transfer = MonitorFeedEffectsWire.monitorTransfer(colorModeCode: code)
        #expect(transfer == .dlog2)
        for ordinal in [0, 1, 5] {
            #expect(try #require(MonitorFeedEffectsWire.packedFalseColorPaint(
                scaleOrdinal: ordinal, transfer: transfer, iso: 800, sourceProfile: source))
                == MonitorFeedEffectsWire.packedFalseColorPaint(
                    scaleOrdinal: ordinal, colorModeCode: code, iso: 800, sourceProfile: source))
            #expect(try #require(MonitorFeedEffectsWire.packedFalseColorWeight(
                scaleOrdinal: ordinal, transfer: transfer, iso: 800, sourceProfile: source))
                == MonitorFeedEffectsWire.packedFalseColorWeight(
                    scaleOrdinal: ordinal, colorModeCode: code, iso: 800, sourceProfile: source))
        }
        #expect(MonitorFeedEffectsWire.assistScalars(transfer: transfer, iso: 800,
            highlightIRE: 95, midtoneIRE: 42, sourceProfile: source)
            == MonitorFeedEffectsWire.assistScalars(colorModeCode: code, iso: 800,
                highlightIRE: 95, midtoneIRE: 42, sourceProfile: source))
        #expect(MonitorFeedEffectsWire.packedFalseColorPaint(
            scaleOrdinal: 9, transfer: .ilog, iso: 800, sourceProfile: source) == nil)
    }
}
