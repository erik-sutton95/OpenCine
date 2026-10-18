import OpenCineAppKitApple
import OpenCineCameraVocabulary

extension DiagnosticCamera {
    /// A camera app's report words for its connected body and handshake phase; no camera is
    /// `"none"` for both family and model.
    public init(family: CameraBodyFamily?, model: String?, phase: CameraConnectionPhase) {
        let familyName = family?.reportName ?? "none"
        let phaseName: String
        switch phase {
        case .idle: phaseName = "idle"
        case .scanning: phaseName = "scanning"
        case .connectingGatt: phaseName = "connectingGatt"
        case .pairing: phaseName = "pairing"
        case .awaitingApproval: phaseName = "awaitingApproval"
        case .readingWifiCreds: phaseName = "readingWifiCreds"
        case .joiningWifi: phaseName = "joiningWifi"
        case .openingDatalink: phaseName = "openingDatalink"
        case .live: phaseName = "live"
        case .failed: phaseName = "failed"
        }
        self.init(family: familyName, model: model ?? "none", phase: phaseName)
    }
}
