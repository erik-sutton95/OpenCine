import HarnessEngine
import Insta360AppleTestSupport
import OpenCineCore
import OpenCineDJI
import OpenCineMedia
import Testing

/// SIMULATED. Plan 6.3 and 11.2 case 12: two sources with different signal profiles and analysis
/// settings stay independent. Configuration is a value per source; the DJI live ceiling is one
/// `ScopeExposureCeiling` per picture source; OpenCineMedia holds no mutable global state.
@MainActor
@Suite struct AnalysisTests {
    @Test func perSourceReadingAndCeilingStayIndependent() throws {
        // Two Pocket feeds in D-Log2 and one Luna in I-Log, in one process.
        let dlog2 = ObservedValue(MonitorTransfer(ColorMode.dLog2), origin: .cameraReported, at: nil)
        let look = DJILook.rec709LookCurve(.dlog2)
        var analysis: [String: AnalysisConfiguration] = [
            "pocket A": AnalysisConfiguration(signal: dlog2, rec709Reading: false, lookCurve: look),
            "pocket B": AnalysisConfiguration(signal: dlog2, rec709Reading: true, lookCurve: look),
        ]
        let ceilingA = DJIScopeExposureCeiling()
        let ceilingB = DJIScopeExposureCeiling()

        // Source A's tap ratchets its own ceiling; B's stays at the measured reference.
        ceilingA.observeTapMax(248, transfer: .dlog2)
        #expect(ceilingA.clipByte(transfer: .dlog2) == 248)
        #expect(ceilingB.clipByte(transfer: .dlog2) == 247)

        let code = 0.6
        let a = try #require(analysis["pocket A"]?.waveIRE(encoded: code, clipByte: ceilingA.clipByte(transfer: .dlog2)))
        let b = try #require(analysis["pocket B"]?.waveIRE(encoded: code, clipByte: ceilingB.clipByte(transfer: .dlog2)))
        #expect(abs(a - b) > 5, "LOG and 709 readings of the same code differ: \(a) vs \(b)")

        // Changing B's reading never moves A.
        analysis["pocket B"]?.rec709Reading = false
        #expect(analysis["pocket A"]?.waveIRE(encoded: code, clipByte: ceilingA.clipByte(transfer: .dlog2)) == a)
    }

    /// Luna's recording profile is camera-reported, but the preview signal is not inferred from it
    /// (an I-Log preview can be flat while its stream metadata says BT.709): the operator states
    /// it, and there is no official Luna look, so the 709 reading stays on the signal.
    @Test func lunaSignalIsStatedNotInferred() throws {
        let camera = FakeLuna()
        camera.colorMode = 2  // I-Log
        let luna = camera.connectedSession()
        #expect(luna.recordingProfile.value == "com.opencapture.insta360.luna.profile.i-log")
        #expect(luna.recordingProfile.origin == .cameraReported)

        let unknown = AnalysisConfiguration(signal: .unknown, rec709Reading: false, lookCurve: nil)
        #expect(unknown.waveIRE(encoded: 0.5, clipByte: nil) == nil, "unknown signal, no reading")

        let stated = ObservedValue(MonitorTransfer.ilog, origin: .operatorProvided, at: nil)
        let log = AnalysisConfiguration(signal: stated, rec709Reading: false, lookCurve: nil)
        var asked709 = log
        asked709.rec709Reading = true
        #expect(DJILook.rec709LookCurve(.ilog) == nil)
        #expect(asked709.waveIRE(encoded: 0.5, clipByte: nil) == log.waveIRE(encoded: 0.5, clipByte: nil))
    }
}
