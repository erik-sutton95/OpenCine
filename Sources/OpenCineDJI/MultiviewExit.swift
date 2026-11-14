import Foundation

/// Why a Multiview camera step failed, in the operator's words. Kotlin twin: `MultiviewFailure`.
public enum MultiviewFailure: LocalizedError, Equatable, Sendable {
    case timeout, unavailable, rejected, network, pairingDeferred
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: "Camera did not respond. Close other camera apps and try again."
        case .unavailable: "Camera is not nearby. Check that it is powered on."
        case .rejected:
            "Camera could not complete this step. Check the Wi-Fi details and try again."
        case .network: "Join the shared Wi-Fi network on this device first."
        case .pairingDeferred: "Camera is not ready to pair again. Please try again."
        case .message(let text): text
        }
    }
}

/// The Multiview pairing reply rule. Kotlin twin: `MultiviewPairing`.
public enum MultiviewPairing {
    /// Exact pairing replies only. A previous network session can answer `00 06` at cleanup: that
    /// is not approval, so it throws `pairingDeferred` and the caller closes the link and retries
    /// before sending an access point command. `00 02` is still waiting; anything else refuses.
    public static func acceptsReply(_ response: Duml.Frame, sequence: UInt16) throws -> Bool {
        guard response.seq == sequence, response.cmdSet == 7, response.cmdId == 0x45,
            response.flags & 128 != 0
        else { return false }
        switch response.payload {
        case [0, 1]: return true
        case [0, 2]: return false
        case [0, 6]: throw MultiviewFailure.pairingDeferred
        default: throw MultiviewFailure.rejected
        }
    }
}

/// One Exit handles the captured post-session `00 06` reply: at most three attempts, waiting
/// between them only after a deferred pairing. Any other failure, cancellation included, ends at
/// once with false; a cancelled return is never reported as success. Kotlin twin:
/// `restoreCameraWiFiWithRetry` (which propagates cancellation instead). Runs on the caller's
/// actor, so the closures may touch its state.
public func restoreCameraWiFiWithRetry(
    isolation: isolated (any Actor)? = #isolation,
    waitBetween: () async -> Void,
    attempt: () async throws -> Bool
) async -> Bool {
    for index in 0..<3 {
        do {
            return try await attempt()
        } catch MultiviewFailure.pairingDeferred where index < 2 {
            await waitBetween()
        } catch {
            return false
        }
    }
    return false
}
