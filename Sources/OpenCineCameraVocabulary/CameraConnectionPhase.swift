import Foundation

/// Where a camera connection is in the Bluetooth -> Wi-Fi -> datalink handshake. Drives the
/// status UI and makes "it stalled" legible about *where* it stalled. The camera apps' view cores
/// name it `ConnectionPhase` (OpenCineCore has its own `ConnectionPhase` for the session state).
public enum CameraConnectionPhase: Equatable, Sendable {
    case idle
    case scanning
    case connectingGatt  // GATT connect + notifications + arm pairing
    case pairing  // SetPairingPIN sent
    case awaitingApproval  // camera showed a prompt — user must tap it
    case readingWifiCreds  // asking the camera for its SSID + passphrase
    case joiningWifi  // NEHotspotConfiguration
    case openingDatalink  // UDP handshake + register + subscribe
    case live  // registered; status pushes flowing
    case failed(String)

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .scanning: "Scanning for camera…"
        case .connectingGatt: "Connecting (Bluetooth)…"
        case .pairing: "Pairing…"
        case .awaitingApproval: "Approve on the camera screen"
        case .readingWifiCreds: "Reading Wi-Fi credentials…"
        case .joiningWifi: "Joining camera Wi-Fi…"
        case .openingDatalink: "Opening datalink…"
        case .live: "Connected"
        case .failed(let why): "Failed: \(why)"
        }
    }
}
