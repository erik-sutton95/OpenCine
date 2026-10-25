import Foundation
import OpenCineNikon
import Testing

@testable import OpenCineNikonAndroid

/// A4-45: Android classifies a failed connect by this code (Kotlin `CameraConnectionFailure`),
/// never by the message, so each case iOS tells apart in `NativeCameraSessionError` keeps its own.
struct AndroidConnectFailureWireTests {
    @Test("the wire codes are the Kotlin CameraConnectionFailure table")
    func wireCodes() {
        #expect(
            AndroidConnectFailure.allCases.map { "\($0)=\($0.rawValue)" } == [
                "other=0", "rejectedInitiator=1", "busy=2", "connectionClosed=3", "timeout=4",
                "pairingChallengeUnavailable=5", "savedProfileRequired=6", "nonNumericHost=7",
                "unreachable=8", "cameraSilent=9",
            ])
    }

    @Test("a body the wake never heard is its own failure, so Android shows the shared silent copy")
    func silentBody() {
        #expect(AndroidConnectFailure(NikonBodyWake.SilentError()) == .cameraSilent)
        #expect(AndroidConnectFailure(NikonBodyWake.SilentError(deviceName: "ZR_6002199")) == .cameraSilent)
    }

    @Test("the dial's wake reports the shared waiting step, then the handshake")
    func wakeProgressPhases() {
        var pushed: [String] = []
        PTPIPClientSession.report(.waiting) { pushed.append("\($0)|\($1)") }
        PTPIPClientSession.report(.answered) { pushed.append("\($0)|\($1)") }
        #expect(
            pushed == [
                "discovering|Waiting for the camera to answer on the network…", "handshaking|",
            ])
    }

    @Test("session errors map to the case iOS recovers from, whatever their message says")
    func sessionErrors() {
        let cases: [(PTPIPClientSessionError, AndroidConnectFailure)] = [
            (.initFailed(.rejectedInitiator), .rejectedInitiator),
            (.initFailed(.busy), .busy),
            // Only rejectedInitiator means the camera forgot this phone (iOS isRejectedInitiator).
            (.initFailed(.unspecified), .unreachable),
            (.connectionClosed, .connectionClosed),
            (.timeout("Init"), .timeout),
            (.pairingChallengeUnavailable, .pairingChallengeUnavailable),
            (.savedProfileRequired, .savedProfileRequired),
            (.nonNumericHost, .nonNumericHost),
            (.connectionFailed("PTP-IP command connection failed: Network is unreachable"), .unreachable),
            (.invalidPacketLength(3), .unreachable),
            (.appControlUnavailable, .other),
        ]
        for (error, expected) in cases {
            #expect(AndroidConnectFailure(error) == expected, "\(error)")
        }
    }

    @Test("a USB handshake failure maps through the error it wraps")
    func usbErrors() {
        #expect(
            AndroidConnectFailure(
                USBHandshakeError(stage: .openSession, underlying: PTPIPClientSessionError.savedProfileRequired))
                == .savedProfileRequired)
        #expect(AndroidConnectFailure(AndroidUSBPTPTransportError.timeout("open session")) == .timeout)
        #expect(AndroidConnectFailure(AndroidUSBPTPTransportError.connectionClosed) == .other)
        #expect(AndroidConnectFailure(CocoaError(.fileNoSuchFile)) == .other)
    }

    @Test("a host name is refused before any socket, as its own failure")
    func nonNumericHost() {
        #expect(throws: PTPIPClientSessionError.nonNumericHost) {
            try PTPIPClientSession.connect(host: "camera.local", port: 15740, timeoutMilliseconds: 1_000)
        }
        #expect(
            PTPIPClientSessionError.nonNumericHost.errorDescription
                == "Enter a numeric IPv4 camera address. Host names are not supported yet.")
    }
}
