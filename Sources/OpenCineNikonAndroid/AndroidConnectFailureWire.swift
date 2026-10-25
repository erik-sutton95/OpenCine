import OpenCineNikon

/// Why a connect attempt failed, as Android's `SessionListener.onFailed(failure, message)`
/// receives it. Android picks its copy and its recovery (escalate to a fresh pairing or not)
/// from this code, never from the message text, as iOS does from `NativeCameraSessionError`.
/// The raw values are a wire contract with Kotlin `CameraConnectionFailure`.
public enum AndroidConnectFailure: Int32, CaseIterable, Sendable {
    /// Anything else; Android shows the message.
    case other = 0
    /// The body refused this initiator: it no longer knows this phone.
    case rejectedInitiator = 1
    /// Another initiator holds the body; the message names the remedy.
    case busy = 2
    /// The body hung up mid-establishment.
    case connectionClosed = 3
    /// The body did not answer in time.
    case timeout = 4
    /// The body offered no pairing code.
    case pairingChallengeUnavailable = 5
    /// The saved camera-side profile does not admit this initiator.
    case savedProfileRequired = 6
    /// The dial target was not a numeric IPv4 address.
    case nonNumericHost = 7
    /// The network or the PTP-IP exchange failed below the camera's own answers.
    case unreachable = 8
    /// The wake asked the network and the body never answered: asleep or not on this network.
    /// Android shows `NikonBodyWake.silentMessage` with its own camera name, the copy iOS shows.
    case cameraSilent = 9

    public init(_ error: Error) {
        if error is NikonBodyWake.SilentError {
            self = .cameraSilent
            return
        }
        if let usb = error as? USBHandshakeError {
            self.init(usb.underlying)
            return
        }
        if let usb = error as? AndroidUSBPTPTransportError {
            if case .timeout = usb { self = .timeout } else { self = .other }
            return
        }
        guard let session = error as? PTPIPClientSessionError else {
            self = .other
            return
        }
        switch session {
        case .initFailed(.rejectedInitiator): self = .rejectedInitiator
        case .initFailed(.busy): self = .busy
        case .connectionClosed: self = .connectionClosed
        case .timeout: self = .timeout
        case .pairingChallengeUnavailable: self = .pairingChallengeUnavailable
        case .savedProfileRequired: self = .savedProfileRequired
        case .nonNumericHost: self = .nonNumericHost
        case .connectionFailed, .initFailed, .unexpectedPacket, .invalidPacketLength,
            .operationRejected, .unsupportedProperty, .invalidPropertyDescriptor,
            .unwritablePropertyDescriptor:
            self = .unreachable
        default: self = .other
        }
    }
}
