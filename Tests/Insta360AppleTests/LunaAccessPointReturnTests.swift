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
    /// A scripted camera behind the Bluetooth link: what each step does, and what it was sent.
    @MainActor private final class Camera {
        var link: Error?
        var authorize: Error?
        var switchMode: Error?
        var reply = Camera.credentials(region: "DK")
        private(set) var sent: [LunaRequest] = []
        private(set) var closes = 0

        func restore() -> LunaAccessPointRestore {
            LunaAccessPointRestore(
                link: { [self] in if let link { throw link } },
                authorize: { [self] in
                    if let authorize { throw authorize }
                    return reply
                },
                send: { [self] request in
                    sent.append(request)
                    if let switchMode { throw switchMode }
                },
                close: { [self] in closes += 1 })
        }

        /// The credential read's reply: the camera's own Wi-Fi and, when given, its region.
        static func credentials(region: String?) -> Data {
            func blob(_ field: Int, _ value: Data) -> Data { try! ProtoMessage.blob(field: field, value: value) }
            let wifi = blob(36, blob(1, Data("LUNA-TEST".utf8)) + blob(2, Data("synthetic-password".utf8)))
            let channels = region.map { blob(37, blob(1, Data($0.utf8))) } ?? Data()
            return Data([0x0a, 0x03, 0x24, 0x25, 0x2b]) + blob(2, wifi + channels)
        }
    }

    @Test func theCameraIsAskedBackOntoItsAccessPointAndNothingElse() async throws {
        let camera = Camera()
        #expect(try await camera.restore().run() == .returned)
        #expect(camera.sent == [try LunaProtocol.wifiModeRequest(.accessPoint, countryCode: "DK")])
        #expect(camera.sent.allSatisfy { $0.command == .setWifiMode }, "never a capture, record or live command")
        #expect(camera.closes == 1)
    }

    @Test func aCameraWithoutARegionIsAskedWithoutOne() async throws {
        let camera = Camera()
        camera.reply = Camera.credentials(region: nil)
        #expect(try await camera.restore().run() == .returned)
        #expect(camera.sent == [try LunaProtocol.wifiModeRequest(.accessPoint, countryCode: nil)])
    }

    @Test func aCameraBluetoothCannotReachIsDeferred() async throws {
        let camera = Camera()
        camera.link = ConnectionFailure.luna(.notFound, "bluetooth.not-nearby", "gone", phase: .link)
        let result = try await camera.restore().run()
        #expect(result.failure?.code == "com.opencapture.insta360.luna.return.not-reachable" && result.isRetryable)
        #expect(camera.sent.isEmpty && camera.closes == 1)
    }

    @Test func aCameraStillSwitchingItsWiFiIsDeferred() async throws {
        let authorizing = Camera()
        authorizing.authorize = LunaProtocolError.cameraBusySwitchingWiFi
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
        authorizing.authorize = timeout
        let switching = Camera()
        switching.switchMode = timeout
        for camera in [authorizing, switching] {
            let result = try await camera.restore().run()
            #expect(result.failure?.code == "com.opencapture.insta360.luna.return.no-answer" && result.isRetryable)
        }
    }

    @Test func aCameraThatDoesNotAuthorizeThisPhoneFails() async throws {
        let camera = Camera()
        camera.authorize = ConnectionFailure.lunaHeldElsewhere
        let result = try await camera.restore().run()
        #expect(result.failure?.code == "com.opencapture.insta360.luna.return.not-authorized" && !result.isRetryable)
        #expect(camera.sent.isEmpty, "nothing is asked of a camera that did not authorize this phone")
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
        camera.authorize = CancellationError()
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
