import Foundation

/// Why a Nikon PTP/IP or USB camera transport or session step failed, with operator copy.
/// Moved from OpenZCine `ios/Runner/NativeCameraSession.swift` with the iOS transports.
public enum NativeCameraSessionError: Error, LocalizedError {
    /// True when the body answered a command with a PTP refusal, rather than losing its reply.
    public static func isCameraRefusal(_ error: any Error) -> Bool {
        if case NativeCameraSessionError.operationRejected = error { return true }
        return false
    }
    /// True when the link to the body failed mid-command (closed, timed out, unreadable), so
    /// the camera stopped answering; never for a refusal or a local precondition.
    public static func isLinkFailure(_ error: any Error) -> Bool {
        switch error as? NativeCameraSessionError {
        case .connectionClosed, .connectionFailed, .timeout, .invalidPacketLength,
            .unexpectedPacket:
            return true
        default: return false
        }
    }
    case noHost
    case connectionFailed(String)
    case connectionClosed
    /// Supplied operation authority expired before the operation request reached the body.
    case commandAuthorityExpired
    case timeout(String)
    case unexpectedPacket(expected: String, actual: PTPIPPacketType)
    case initFailed(PTPIPInitFailReason)
    case operationRejected(PTPOperationCode, PTPResponseCode)
    /// An object star-rating write the body refused, carrying the exact wire code so the UI can
    /// name it (a state-based refusal like Access Denied is the discriminator we surface).
    case objectRatingRejected(response: PTPResponseCode, rawCode: UInt16)
    case invalidPacketLength(UInt32)
    case localNetworkPermissionDenied
    case pairingRejected
    case pairingChallengeUnavailable
    case savedProfileRequired

    public var errorDescription: String? {
        switch self {
        case .noHost:
            return "Enter the camera IP address, or connect to the camera's Wi-Fi network first."
        case .connectionFailed(let message):
            return message
        case .connectionClosed:
            return "The camera closed the connection."
        case .commandAuthorityExpired:
            return "Camera control expired before the command was sent."
        case .timeout(let label):
            return "\(label) timed out."
        case .unexpectedPacket(let expected, let actual):
            return "Expected \(expected), got PTP-IP packet \(actual.rawValue)."
        case .initFailed(.busy):
            return
                "Another device is connected to this camera. Disconnect it there, then try again."
        case .initFailed(let reason):
            return "The camera rejected the PTP-IP handshake: \(reason)."
        case .operationRejected(let operation, let response):
            return "Camera rejected \(operation) with response \(response)."
        case .objectRatingRejected(let response, let rawCode):
            return
                "Camera refused the rating write (\(response), \(String(format: "0x%04X", rawCode)))."
        case .invalidPacketLength(let length):
            return "Invalid PTP-IP packet length \(length)."
        case .localNetworkPermissionDenied:
            return
                "iOS blocked local network socket access. If Local Network is enabled in Settings, confirm the phone is on the camera Wi-Fi/LAN and try again."
        case .pairingRejected:
            return "Pairing was rejected."
        case .pairingChallengeUnavailable:
            return
                "The Nikon did not provide a pairing code. Restart Connect to PC on the camera, then pair again."
        case .savedProfileRequired:
            return "The camera requires first-time pairing before app control can start."
        }
    }
}
