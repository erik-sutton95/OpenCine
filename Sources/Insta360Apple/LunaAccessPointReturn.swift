import Foundation
import Insta360Protocol
import OpenCineCore

/// What returning a Luna to its own Wi-Fi came to (Kotlin `LunaAccessPointReturn`, same cases).
/// Multiview's close asks every camera it moved back onto its own access point; a camera that is
/// not back stays in the caller's cleanup record for a later try.
public enum LunaAccessPointReturn: Equatable, Sendable {
    /// The camera accepted the switch to its own access point.
    case returned
    /// Not now: Bluetooth could not reach it, it is still switching its Wi-Fi, or it did not
    /// answer. Trying again a little later may succeed.
    case deferred(ConnectionFailure)
    /// Trying again now will not help: the camera did not authorize this phone (it declined, another
    /// phone holds it, or it is no supported Luna) or refused the switch.
    case failed(ConnectionFailure)

    /// A deferred result: the caller may try again.
    public var isRetryable: Bool {
        if case .deferred = self { return true }
        return false
    }

    /// Why the camera is not back; nil once it returned.
    public var failure: ConnectionFailure? {
        switch self {
        case .returned: nil
        case .deferred(let failure), .failed(let failure): failure
        }
    }

    /// Up to `attempts` tries of `attempt`, with `waitBetween` before each retry of a deferred
    /// result (DJI `restoreCameraWiFiWithRetry`): the first returned or failed result ends it, and
    /// the last deferred result is the answer when every try was deferred. Cancellation is thrown,
    /// never reported as a result.
    @MainActor
    public static func retrying(
        attempts: Int = 3, waitBetween: () async throws -> Void,
        _ attempt: () async throws -> LunaAccessPointReturn
    ) async throws -> LunaAccessPointReturn {
        var tries = 0
        while true {
            try Task.checkCancellation()
            tries += 1
            let result = try await attempt()
            guard result.isRetryable, tries < max(attempts, 1) else { return result }
            try await waitBetween()
        }
    }

    static func failure(
        _ reason: ConnectionFailure.Reason, _ code: String, _ message: String
    ) -> ConnectionFailure {
        ConnectionFailure(
            reason: reason, title: "Couldn’t return the camera to its Wi-Fi", message: message,
            actions: [.retry], code: "\(LunaCameraSession.integration.rawValue).return.\(code)")
    }

    static let notReachable = failure(
        .notFound, "not-reachable",
        "The camera is not reachable over Bluetooth. Keep it turned on and nearby, then try again.")
    static let cameraBusy = failure(
        .other, "camera-busy", "The camera is still switching its Wi-Fi. Wait a moment, then try again.")
    static let noAnswer = failure(
        .timedOut, "no-answer", "The camera did not answer over Bluetooth. Keep it nearby, then try again.")
    static let notAuthorized = failure(
        .notApproved, "not-authorized",
        "The camera did not approve this phone. Close the Insta360 app on other devices, approve the connection on the camera, then try again.")
    static let refused = failure(.other, "refused", "The camera refused to switch back to its own Wi-Fi.")
    /// A backend without Bluetooth (a Mac already on the camera's access point, a test port).
    static let unsupported = failure(
        .unsupported, "unsupported", "Returning the camera to its own Wi-Fi needs Bluetooth on a phone.")
}

/// The camera's side of a return to its own Wi-Fi: Bluetooth reaches it, it authorizes this
/// phone (`LunaBluetoothAuthorization`, whose credential read names the camera's region), and one
/// SET_WIFI_MODE 147 on the same link asks it onto its access point. The link always closes
/// afterwards. Nothing else is sent: no capture, record or live request, so a recording continues;
/// and the phone joins no network. Kotlin twin: `LunaAccessPointRestore`.
@MainActor
struct LunaAccessPointRestore {
    /// Bluetooth reaches the camera.
    var link: @MainActor () async throws -> Void
    /// The authorization on that link; its `send` also carries the switch.
    var authorization: LunaBluetoothAuthorization
    /// This phone's approval identity.
    var identity: UUID
    /// Ends the Bluetooth link; runs after every outcome.
    var close: @MainActor () -> Void

    /// The return's result. Throws only `CancellationError`.
    func run() async throws -> LunaAccessPointReturn {
        defer { close() }
        do {
            try await link()
        } catch {
            try Self.rethrowCancellation(error)
            return .deferred(LunaAccessPointReturn.notReachable)
        }
        let reply: Data
        do {
            reply = try await authorization.run(identity: identity).credentials
        } catch {
            try Self.rethrowCancellation(error)
            return Self.authorizationResult(error)
        }
        do {
            let region = try? LunaProtocol.wifiCountryCode(response: reply)
            _ = try await authorization.send(LunaProtocol.wifiModeRequest(.accessPoint, countryCode: region))
        } catch {
            try Self.rethrowCancellation(error)
            switch error {
            case LunaProtocolError.cameraBusySwitchingWiFi:
                return .deferred(LunaAccessPointReturn.cameraBusy)
            case LunaProtocolError.cameraRejectedRequest:
                return .failed(LunaAccessPointReturn.refused)
            default:
                return .deferred(LunaAccessPointReturn.noAnswer)
            }
        }
        return .returned
    }

    /// A failed authorization: final only when the camera itself said no (it did not approve this
    /// phone, another phone holds it, it is no supported Luna). A Bluetooth link that dropped, a
    /// camera still switching its Wi-Fi or one that did not answer may answer a later try.
    static func authorizationResult(_ error: Error) -> LunaAccessPointReturn {
        if case LunaProtocolError.cameraBusySwitchingWiFi = error {
            return .deferred(LunaAccessPointReturn.cameraBusy)
        }
        if let failure = error as? ConnectionFailure {
            switch failure.reason {
            case .timedOut: return .deferred(LunaAccessPointReturn.noAnswer)
            case .notApproved, .heldElsewhere, .unsupported, .wrongCamera:
                return .failed(LunaAccessPointReturn.notAuthorized)
            default: return .deferred(LunaAccessPointReturn.notReachable)
            }
        }
        switch error {
        case LunaProtocolError.authorizationRejected, LunaProtocolError.unsupportedAuthorizationStatus,
            LunaProtocolError.unexpectedModel:
            return .failed(LunaAccessPointReturn.notAuthorized)
        default:
            return .deferred(LunaAccessPointReturn.notReachable)
        }
    }

    private static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError { throw error }
        try Task.checkCancellation()
    }
}
