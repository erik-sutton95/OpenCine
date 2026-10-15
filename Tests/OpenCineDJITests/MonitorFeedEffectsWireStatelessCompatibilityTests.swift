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
}
