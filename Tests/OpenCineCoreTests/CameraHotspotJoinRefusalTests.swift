import Foundation
import OpenCineCore
import Testing

/// The platform's refusal codes map to one shared vocabulary, and no platform text or raw
/// code reaches operator copy. The raw code stays in the closed journal token.
@Suite struct CameraHotspotJoinRefusalTests {
    private static let settingsCopy =
        "This device couldn't join Camera automatically. Join it in Settings > Wi-Fi, then come back."

    @Test func mapsEveryKnownPlatformCodeToItsMeaning() throws {
        let table: [(code: Int, reason: CameraHotspotJoinRefusal.Reason)] = [
            (0, .invalidConfiguration),
            (1, .invalidSSID),
            (2, .invalidPassphrase),
            (3, .invalidPassphrase),
            (4, .invalidConfiguration),
            (5, .invalidConfiguration),
            (6, .invalidConfiguration),
            (7, .userDenied),
            (8, .internalError),
            (9, .pending),
            (10, .systemConfiguration),
            (11, .unknown),
            (12, .joinOnceNotSupported),
            (13, .alreadyAssociated),
            (14, .applicationNotInForeground),
            (15, .invalidSSID),
            (16, .userUnauthorized),
            (17, .systemDenied),
            (99, .other(99)),
        ]
        for entry in table {
            let refusal = try #require(
                CameraHotspotJoinRefusal(error: Self.platformError(entry.code), network: "Camera"))
            #expect(refusal.reason == entry.reason, "code \(entry.code)")
            #expect(refusal.rawCode == entry.code, "code \(entry.code)")
            #expect(
                refusal.diagnosticsCode == "error.connection.wifi-join.code\(entry.code)",
                "code \(entry.code)")
        }
    }

    @Test func internalRefusalOffersSettingsAndRetry() throws {
        let refusal = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(8), network: "Camera"))
        #expect(refusal.message == Self.settingsCopy)
        #expect(refusal.actions == [.openSettings, .retry])

        let failure = refusal.failure(integration: IntegrationID("test.integration"))
        #expect(failure.reason == .joinFailed)
        #expect(failure.phase == .joiningNetwork)
        #expect(failure.title == "Couldn't join the camera Wi-Fi")
        #expect(failure.message == Self.settingsCopy)
        #expect(failure.actions == [.openSettings, .retry])
        #expect(failure.code == "test.integration.error.connection.wifi-join.code8")
    }

    @Test func everySelfRefusalInTheSameFamilyOffersSettings() throws {
        for code in [8, 9, 10, 11, 14, 16, 17, 99] {
            let refusal = try #require(
                CameraHotspotJoinRefusal(error: Self.platformError(code), network: "Camera"))
            #expect(refusal.actions == [.openSettings, .retry], "code \(code)")
            #expect(refusal.message == Self.settingsCopy, "code \(code)")
            #expect(
                refusal.diagnosticsCode == "error.connection.wifi-join.code\(code)", "code \(code)")
        }
    }

    @Test func userDeniedKeepsTheCancelledCopy() throws {
        let refusal = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(7), network: "Camera"))
        #expect(refusal.reason == .userDenied)
        #expect(refusal.message == "Join the camera Wi-Fi network to continue.")
        #expect(refusal.actions == [.retry])
        #expect(
            refusal.failure(integration: IntegrationID("test.integration")).reason == .cancelled)
    }

    @Test func invalidSSIDAndKeySayWhatLooksWrong() throws {
        let badName = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(1), network: "Camera"))
        #expect(badName.message.contains("name looks wrong"))
        #expect(badName.actions == [.retry])

        let badPrefix = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(15), network: "Camera"))
        #expect(badPrefix.message.contains("name looks wrong"))
        #expect(badPrefix.actions == [.retry])

        let badKey = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(2), network: "Camera"))
        #expect(badKey.message.contains("key looks wrong"))
        #expect(badKey.actions == [.pairAgain, .retry])

        // WEP has its own code, but the operator needs the same key answer and the raw code stays.
        let badWEPKey = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(3), network: "Camera"))
        #expect(badWEPKey.reason == .invalidPassphrase)
        #expect(badWEPKey.rawCode == 3)
        #expect(badWEPKey.diagnosticsCode == "error.connection.wifi-join.code3")
    }

    @Test func platformTextNeverReachesOperatorCopy() throws {
        for code in 0...17 {
            let text = "raw platform text \(code)"
            let refusal = try #require(
                CameraHotspotJoinRefusal(
                    error: Self.platformError(code, text: text), network: "Camera"))
            #expect(!refusal.message.contains(text), "code \(code)")
            #expect(!refusal.message.contains("NEHotspot"), "code \(code)")
            #expect(!refusal.message.contains("internal error"), "code \(code)")
            #expect(!refusal.message.contains("iPhone"), "code \(code): iPad also uses this copy")
            #expect(refusal.errorDescription == refusal.message, "code \(code)")
            #expect(!refusal.message.contains("\(code)"), "code \(code)")

            let failure = refusal.failure(integration: IntegrationID("test.integration"))
            #expect(!failure.message.contains(text), "code \(code)")
            #expect(!failure.title.contains("internal error"), "code \(code)")
        }
    }

    @Test func anEmptyNetworkUsesTheGenericName() throws {
        let refusal = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(8), network: ""))
        #expect(refusal.message.contains("the camera network"))
    }

    @Test func bridgingToNSErrorKeepsThePlatformDomainCodeAndCleanCopy() throws {
        let refusal = try #require(
            CameraHotspotJoinRefusal(error: Self.platformError(8), network: "Camera"))
        let bridged = refusal as NSError
        #expect(bridged.domain == CameraHotspotJoinRefusal.platformErrorDomain)
        #expect(bridged.code == 8)
        #expect(bridged.localizedDescription == refusal.message)
        #expect(!bridged.localizedDescription.contains("internal error"))
        let roundTrip = try #require(
            CameraHotspotJoinRefusal(error: bridged, network: "Camera"))
        #expect(roundTrip.reason == .internalError)
        #expect(roundTrip.rawCode == 8)
    }

    @Test func aHostCanMapAPlatformCodeWithoutAnNSError() {
        let refusal = CameraHotspotJoinRefusal(code: 8, network: "Camera")
        #expect(refusal.reason == .internalError)
        #expect(refusal.rawCode == 8)
        #expect(refusal.diagnosticsCode == "error.connection.wifi-join.code8")
    }

    @Test func onlyRefusalsAnotherAttemptCanFixAreRetried() {
        // A decline is the operator's answer, and a wrong name, key or configuration fails the
        // same way every time: the join loop surfaces those at once. A platform refusal of its
        // own request (internal, pending, busy) can pass on the next attempt.
        for code in [0, 1, 2, 3, 4, 5, 6, 7, 12, 15] {
            #expect(!CameraHotspotJoinRefusal(code: code, network: "Camera").retryMayJoin, "code \(code)")
        }
        for code in [8, 9, 10, 11, 14, 16, 17, 99] {
            #expect(CameraHotspotJoinRefusal(code: code, network: "Camera").retryMayJoin, "code \(code)")
        }
    }

    @Test func anotherDomainIsNotARefusal() {
        let error = NSError(domain: "SomeOtherDomain", code: 8)
        #expect(CameraHotspotJoinRefusal(error: error, network: "Camera") == nil)
    }

    private static func platformError(_ code: Int, text: String = "internal error.") -> NSError {
        NSError(
            domain: CameraHotspotJoinRefusal.platformErrorDomain, code: code,
            userInfo: [NSLocalizedDescriptionKey: text])
    }
}
