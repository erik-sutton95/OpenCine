@testable import Insta360Apple
@testable import Insta360Protocol
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// Firmware v1.2.7 leaves a Wi-Fi or hotspot setup's network about 60 s after each join; the
/// keep-alive asks it to join again over the control link. Waits run on a manual clock.
@MainActor @Suite struct LunaStationKeepAliveTests {
    private static let network = LunaStationNetwork(ssid: "Studio", password: "synthetic1", hotspot: false)

    @MainActor private final class Link {
        var sent: [LunaRequest] = []
        var failing = false
        var current = true
        var logs: [String] = []
        func send(_ request: LunaRequest) throws {
            sent.append(request)
            if failing { throw LunaProtocolError.invalidField(0) }
        }
    }

    private func keepAlive(_ link: Link, clock: ManualHostClock) -> LunaStationKeepAlive {
        LunaStationKeepAlive(
            send: { try link.send($0) }, clock: clock.clock, isCurrent: { link.current },
            log: { link.logs.append($0) })
    }

    @Test func theRequestIsThePlainJoinOfTheSameNetwork() throws {
        let request = try LunaProtocol.stationKeepAliveRequest(ssid: "Studio", password: "synthetic1")
        let join = try LunaProtocol.stationJoinRequest(ssid: "Studio", password: "synthetic1")
        #expect(request.wireCode == 112)
        #expect(!request.requiresEncryption)
        #expect(request.body == join.body)
        #expect(LunaProtocol.stationKeepAliveInterval < .seconds(60))
    }

    @Test(.timeLimit(.minutes(1)))
    func theJoinIsSentAtOnceThenEveryInterval() async throws {
        let link = Link()
        let clock = ManualHostClock()
        let run = Task { @MainActor in await keepAlive(link, clock: clock).run(Self.network) }
        try await clock.waitForSleeps(1)
        #expect(link.sent.count == 1)
        clock.advance(by: LunaProtocol.stationKeepAliveInterval)
        try await clock.waitForSleeps(1)
        #expect(link.sent.count == 2)
        clock.advance(by: LunaProtocol.stationKeepAliveInterval)
        try await clock.waitForSleeps(1)
        #expect(link.sent.count == 3)
        #expect(link.sent.allSatisfy { $0.wireCode == 112 })
        run.cancel()
        await run.value
    }

    @Test(.timeLimit(.minutes(1)))
    func aMissedAnswerIsLoggedAndTheNextJoinStillGoes() async throws {
        let link = Link()
        link.failing = true
        let clock = ManualHostClock()
        let run = Task { @MainActor in await keepAlive(link, clock: clock).run(Self.network) }
        try await clock.waitForSleeps(1)
        link.failing = false
        clock.advance(by: LunaProtocol.stationKeepAliveInterval)
        try await clock.waitForSleeps(1)
        #expect(link.sent.count == 2)
        #expect(link.logs == [
            "luna: station keep-alive not answered (1 in a row)",
            "luna: station keep-alive answered again",
        ])
        #expect(!link.logs.contains { $0.contains("synthetic1") })
        run.cancel()
        await run.value
    }

    @Test(.timeLimit(.minutes(1)))
    func itStopsOnceTheConnectionIsGone() async throws {
        let link = Link()
        let clock = ManualHostClock()
        let run = Task { @MainActor in await keepAlive(link, clock: clock).run(Self.network) }
        try await clock.waitForSleeps(1)
        link.current = false
        clock.advance(by: LunaProtocol.stationKeepAliveInterval)
        await run.value
        #expect(link.sent.count == 1)
    }
}
