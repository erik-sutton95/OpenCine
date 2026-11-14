import CryptoKit
import Foundation
@testable import Insta360Apple
@testable import Insta360Protocol
import OpenCineCore
import Testing

/// Returning a Luna to its own Wi-Fi when Multiview closes (Pocket's Exit): Bluetooth reaches and
/// authorizes the camera, one SET_WIFI_MODE 147 asks it back onto its access point, and the link
/// closes. The phone joins nothing and no recording is stopped. Kotlin mirror:
/// `LunaAccessPointReturnTest`, same method names.
@MainActor @Suite struct LunaAccessPointReturnTests {
    /// A camera behind the Bluetooth link: it answers the real authorization the backend runs
    /// (identity, key exchange, approval, credential read) and records every request it receives.
    @MainActor private final class Camera {
        var link: Error?
        /// Each request of these commands is answered with the error instead.
        var fails: [LunaCommand: Error] = [:]
        var switchMode: Error?
        var authorization = LunaAuthorizationStatus.authorized
        /// What waiting for the operator's approval ends with (nil: approved).
        var approval: Error?
        var region: String? = "DK"
        private(set) var sent: [LunaRequest] = []
        private(set) var closes = 0
        private let key = P256.KeyAgreement.PrivateKey()

        func restore() -> LunaAccessPointRestore {
            LunaAccessPointRestore(
                link: { [self] in if let link { throw link } },
                authorization: LunaBluetoothAuthorization(
                    send: { [self] request in try answer(request) }, agreed: { _ in },
                    awaitApproval: { [self] _ in if let approval { throw approval } }, appName: "Tests"),
                identity: UUID(), close: { [self] in closes += 1 })
        }

        private func answer(_ request: LunaRequest) throws -> Data {
            sent.append(request)
            if let error = fails[request.command] { throw error }
            switch request.command {
            case .getOptions where request.body == LunaProtocol.wifiCredentialsRequest.body:
                return Self.credentials(region: region)
            case .getOptions:
                return Self.options([48, 15, 30], [
                    48: Data(LunaProtocol.model.utf8), 15: Data("SN-LUNA".utf8), 30: Data("1.1.15".utf8),
                ])
            case .encryptionCapabilities: return try ProtoMessage.integer(field: 1, value: 3)
            case .keyExchange:
                return try ProtoMessage.integer(field: 1, value: 1)
                    + ProtoMessage.blob(field: 2, value: key.publicKey.x963Representation)
            case .checkAuthorization: return try ProtoMessage.integer(field: 1, value: authorization.rawValue)
            case .setWifiMode:
                if let switchMode { throw switchMode }
                return Data()
            default: return Data()
            }
        }

        private static func blob(_ field: Int, _ value: Data) -> Data { try! ProtoMessage.blob(field: field, value: value) }

        /// A GET_OPTIONS reply: the option numbers, then the options.
        private static func options(_ numbers: [UInt8], _ values: [Int: Data]) -> Data {
            blob(1, Data(numbers)) + blob(2, values.sorted { $0.key < $1.key }.reduce(Data()) { $0 + blob($1.key, $1.value) })
        }

        /// The credential read's reply: the camera's own Wi-Fi and, when given, its region.
        static func credentials(region: String?) -> Data {
            let wifi = blob(36, blob(1, Data("LUNA-TEST".utf8)) + blob(2, Data("synthetic-password".utf8)))
            let channels = region.map { blob(37, blob(1, Data($0.utf8))) } ?? Data()
            return Data([0x0a, 0x03, 0x24, 0x25, 0x2b]) + blob(2, wifi + channels)
        }
    }

    /// Commands that start or stop a recording, a photo or the live picture: a return sends none.
    private static let capture: Set<LunaCommand> = [
        .startCapture, .stopCapture, .takePicture, .startTimelapse, .stopTimelapse, .startLive, .stopLive,
    ]

    @Test func theCameraIsAskedBackOntoItsAccessPointAndNothingElse() async throws {
        let camera = Camera()
        #expect(try await camera.restore().run() == .returned)
        #expect(camera.sent.allSatisfy { !Self.capture.contains($0.command) }, "never a capture, record or live command")
        #expect(camera.sent.filter { $0.command == .setWifiMode } == [try LunaProtocol.wifiModeRequest(.accessPoint, countryCode: "DK")])
        #expect(camera.sent.last?.command == .setWifiMode, "the switch is the last request")
        #expect(camera.closes == 1)
    }

    @Test func aCameraWithoutARegionIsAskedWithoutOne() async throws {
        let camera = Camera()
        camera.region = nil
        #expect(try await camera.restore().run() == .returned)
        #expect(camera.sent.last == (try LunaProtocol.wifiModeRequest(.accessPoint, countryCode: nil)))
    }

    @Test func aCameraBluetoothCannotReachIsDeferred() async throws {
        let camera = Camera()
        camera.link = ConnectionFailure.luna(.notFound, "bluetooth.not-nearby", "gone", phase: .link)
        let result = try await camera.restore().run()
        #expect(result.failure?.code == "com.opencapture.insta360.luna.return.not-reachable" && result.isRetryable)
        #expect(camera.sent.isEmpty && camera.closes == 1)
    }

    /// A camera at the edge of Bluetooth range drops the link during the key exchange: a later try
    /// may reach it, so the return is deferred, never "not authorized".
    @Test func aBluetoothDropDuringAuthorizationIsDeferred() async throws {
        let camera = Camera()
        camera.fails[.checkAuthorization] = ConnectionFailure.luna(.linkLost, "link.dropped", "Bluetooth dropped")
        let result = try await camera.restore().run()
        #expect(result.failure?.code == "com.opencapture.insta360.luna.return.not-reachable" && result.isRetryable)
        #expect(!camera.sent.contains { $0.command == .setWifiMode })
        #expect(camera.closes == 1)
    }

    @Test func aCameraStillSwitchingItsWiFiIsDeferred() async throws {
        let authorizing = Camera()
        authorizing.fails[.getOptions] = LunaProtocolError.cameraBusySwitchingWiFi
        let switching = Camera()
        switching.switchMode = LunaProtocolError.cameraBusySwitchingWiFi
        for camera in [authorizing, switching] {
            let result = try await camera.restore().run()
            #expect(result.failure?.code == "com.opencapture.insta360.luna.return.camera-busy" && result.isRetryable)
            #expect(camera.closes == 1)
        }
    }

    @Test func aCameraThatDoesNotAnswerIsDeferred() async throws {
        let timeout = ConnectionFailure.luna(.timedOut, "command.timeout", "no answer")
        let authorizing = Camera()
        authorizing.fails[.keyExchange] = timeout
        let switching = Camera()
        switching.switchMode = timeout
        for camera in [authorizing, switching] {
            let result = try await camera.restore().run()
            #expect(result.failure?.code == "com.opencapture.insta360.luna.return.no-answer" && result.isRetryable)
        }
    }

    @Test func aCameraThatDoesNotAuthorizeThisPhoneFails() async throws {
        let camera = Camera()
        camera.authorization = .approvalRequired
        camera.approval = ConnectionFailure.luna(.notApproved, "approval.timeout", "Approval timed out.")
        let result = try await camera.restore().run()
        #expect(result.failure?.code == "com.opencapture.insta360.luna.return.not-authorized" && !result.isRetryable)
        #expect(!camera.sent.contains { $0.command == .setWifiMode }, "nothing is asked of a camera that did not authorize this phone")
        #expect(camera.closes == 1)
    }

    @Test func aCameraThatRefusesTheSwitchFails() async throws {
        let camera = Camera()
        camera.switchMode = LunaProtocolError.cameraRejectedRequest
        let result = try await camera.restore().run()
        #expect(result.failure?.code == "com.opencapture.insta360.luna.return.refused" && !result.isRetryable)
    }

    @Test func cancellationIsNeverAResult() async {
        let camera = Camera()
        camera.fails[.encryptionCapabilities] = CancellationError()
        await #expect(throws: CancellationError.self) { try await camera.restore().run() }
        #expect(camera.closes == 1)
    }

    // The bounded retry (DJI `restoreCameraWiFiWithRetry`).

    private static let busy = LunaAccessPointReturn.deferred(
        ConnectionFailure.luna(.other, "return.camera-busy", "busy"))

    @Test func aDeferredReturnIsRetriedAfterAWait() async throws {
        var attempts = 0
        var waits = 0
        let result = try await LunaAccessPointReturn.retrying(waitBetween: { waits += 1 }) {
            attempts += 1
            return attempts == 1 ? Self.busy : .returned
        }
        #expect(result == .returned && attempts == 2 && waits == 1)
    }

    @Test func repeatedDeferralStopsAtTheAttemptLimit() async throws {
        var attempts = 0
        var waits = 0
        let result = try await LunaAccessPointReturn.retrying(waitBetween: { waits += 1 }) {
            attempts += 1
            return Self.busy
        }
        #expect(result == Self.busy && attempts == 3 && waits == 2, "no wait after the last attempt")
    }

    @Test func aFailedReturnIsNotRetried() async throws {
        let refused = LunaAccessPointReturn.failed(ConnectionFailure.luna(.other, "return.refused", "no"))
        var attempts = 0
        let result = try await LunaAccessPointReturn.retrying(waitBetween: { Issue.record("unexpected retry") }) {
            attempts += 1
            return refused
        }
        #expect(result == refused && attempts == 1)
    }

    @Test func cancellationDoesNotBecomeAReportedResult() async {
        await #expect(throws: CancellationError.self) {
            try await LunaAccessPointReturn.retrying(waitBetween: {}) { throw CancellationError() }
        }
    }
}
