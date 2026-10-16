import OpenCineAppKitApple
import OpenCineCameraControls
import OpenCineCameraVocabulary
import Testing

/// The report words a camera app's diagnostics name its body and phase with.
@Suite struct DiagnosticCameraVocabularyTests {
    @Test func noCameraIsNone() {
        #expect(
            DiagnosticCamera(family: nil, model: nil, phase: .idle)
                == DiagnosticCamera(family: "none", model: "none", phase: "idle"))
    }

    @Test func familiesAndPhasesKeepTheirReportNames() {
        #expect(DiagnosticCamera(family: .nano, model: "Body", phase: .connectingGatt).family == "nano")
        #expect(DiagnosticCamera(family: .pocket, model: "Body", phase: .live).phase == "live")
        #expect(DiagnosticCamera(family: .other, model: "Body", phase: .failed("no route")).phase == "failed")
        #expect(DiagnosticCamera(family: .other, model: "Body", phase: .readingWifiCreds).model == "Body")
    }
}
