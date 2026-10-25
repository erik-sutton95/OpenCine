import Foundation
import Testing

@testable import OpenCineNikonAndroid

#if canImport(Android)
    import Android
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// The Android session layer wakes a body only when its command-channel connect found no route or
/// ran into the connect deadline; a refusal proves the host is up (iOS twin:
/// `PTPIPTransportWakeWorthyTests`).
@Suite struct PTPIPClientSessionWakeWorthyTests {
    private struct SocketError: Error {}

    @Test("Only no route, a host held down and the connect deadline are worth a wake")
    func classification() {
        for code in [EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ETIMEDOUT, ETIME] {
            #expect(PTPIPClientSession.isWakeWorthyDial(error: SocketError(), errno: code))
        }
        #expect(
            PTPIPClientSession.isWakeWorthyDial(
                error: PTPIPClientSessionError.timeout("command"), errno: 0))
        for code in [ECONNREFUSED, ECONNRESET, Int32(0)] {
            #expect(!PTPIPClientSession.isWakeWorthyDial(error: SocketError(), errno: code))
        }
    }
}
