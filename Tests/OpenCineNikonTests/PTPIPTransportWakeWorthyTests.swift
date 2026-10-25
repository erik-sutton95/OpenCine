#if canImport(Darwin) && canImport(os)
    import Darwin
    import Testing

    @testable import OpenCineNikon

    /// The iOS transport wakes a body only when its command-channel connect found no route or ran
    /// into the connect deadline; a refusal proves the host is up (Android twin:
    /// `PTPIPClientSessionWakeWorthyTests`).
    @Suite struct PTPIPTransportWakeWorthyTests {
        private struct SocketError: Error {}

        @Test("Only no route, a host held down and the connect deadline are worth a wake")
        func classification() {
            for code in [EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ETIMEDOUT, ETIME] {
                #expect(PTPIPTransport.isWakeWorthyDial(error: SocketError(), errno: code))
            }
            #expect(
                PTPIPTransport.isWakeWorthyDial(
                    error: NativeCameraSessionError.timeout("command"), errno: 0))
            for code in [ECONNREFUSED, ECONNRESET, Int32(0)] {
                #expect(!PTPIPTransport.isWakeWorthyDial(error: SocketError(), errno: code))
            }
        }
    }
#endif
