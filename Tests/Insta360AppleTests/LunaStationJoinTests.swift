@testable import Insta360Apple
@testable import Insta360Protocol
import OpenCineCore
import OpenCineCoreTestSupport
import Testing

/// The camera's side of a Wi-Fi or hotspot setup: the join request and its result over
/// Bluetooth. A scripted camera answers each join; the waits run on a manual clock, so nothing
/// waits in real time.
@MainActor @Suite struct LunaStationJoinTests {
    private static let network = LunaStationNetwork(ssid: "Studio", password: "synthetic1", hotspot: false)

    /// One answer per join request, in order.
    private enum Answer {
        /// Reply 505; `started` posts 8215 as the camera's Wi-Fi comes back.
        case busy(started: Bool)
        /// Reply 200, then these notifications.
        case accepted([LunaStationEvent])
    }

    @MainActor private final class Camera {
        let events = LunaStationEvents()
        var answers: [Answer]
        var joins = 0
        init(_ answers: [Answer]) { self.answers = answers }

        func send(_ request: LunaRequest) throws {
            #expect(request.command == .setWifiConnectionInfo)
            joins += 1
            switch answers.isEmpty ? .accepted([]) : answers.removeFirst() {
            case .busy(let started):
                if started { events.post(.wiFiStarted) }
                throw LunaProtocolError.cameraBusySwitchingWiFi
            case .accepted(let notifications):
                for notification in notifications { events.post(notification) }
            }
        }
    }

    private static func result(
        _ outcome: LunaStationJoinResult.Outcome, ssid: String = "Studio", password: String = "synthetic1"
    ) -> LunaStationEvent {
        .result(.init(outcome: outcome, ssid: ssid, address: nil, echoedPassword: password))
    }

    private func join(_ camera: Camera, clock: ManualHostClock = ManualHostClock()) -> LunaStationJoin {
        LunaStationJoin(
            send: { try camera.send($0) }, events: camera.events, clock: clock.clock,
            checkCurrent: {}, timing: .init(settle: .zero))
    }

    /// Runs `join` to the end, moving `clock` past each wait it parks on.
    private func finish(
        _ join: LunaStationJoin, _ network: LunaStationNetwork = Self.network, clock: ManualHostClock,
        step: Duration
    ) async -> Result<LunaStationJoinResult, Error> {
        let run = Task { @MainActor in try await join.run(network) }
        var advances = 0
        while advances < 10 {
            var turns = 0
            while clock.pendingSleeps == 0, turns < 100_000 {
                turns += 1
                await Task.yield()
            }
            if clock.pendingSleeps == 0 { break }
            clock.advance(by: step)
            advances += 1
        }
        return await run.result
    }

    @Test func theCameraJoinsWhenItAnswersTheJoin() async throws {
        let camera = Camera([.accepted([Self.result(.joined)])])
        let result = try await join(camera).run(Self.network)
        #expect(result.outcome == .joined)
        #expect(camera.joins == 1)
    }

    @Test func aCameraStillSwitchingItsWiFiIsAskedAgainOnceItsWiFiStarted() async throws {
        // Reply 505 right after the role switch; 8215 when its Wi-Fi is back (the official app's flow).
        let camera = Camera([.busy(started: true), .accepted([Self.result(.joined)])])
        let result = try await join(camera).run(Self.network)
        #expect(result.outcome == .joined)
        #expect(camera.joins == 2)
    }

    @Test func aBusyCameraThatNeverSaysItsWiFiStartedIsAskedAgainAfterTheWait() async throws {
        let clock = ManualHostClock()
        let camera = Camera([.busy(started: false), .accepted([Self.result(.joined)])])
        let outcome = await finish(join(camera, clock: clock), clock: clock, step: .seconds(38))
        #expect(try outcome.get().outcome == .joined)
        #expect(camera.joins == 2)
    }

    @Test func aCameraThatStaysBusyEndsWithACameraBusyFailure() async throws {
        let camera = Camera([.busy(started: true), .busy(started: true), .busy(started: true)])
        await #expect {
            try await join(camera).run(Self.network)
        } throws: { error in
            (error as? ConnectionFailure)?.code == "com.opencapture.insta360.luna.station.camera-busy"
        }
        #expect(camera.joins == 3)
    }

    @Test func aLateResultFromAnEarlierJoinIsNotThisJoinsAnswer() async throws {
        // The first try went out without the password; its refusal arrives after this join.
        let camera = Camera([
            .accepted([Self.result(.wrongPassword, password: ""), Self.result(.joined)])
        ])
        let result = try await join(camera).run(Self.network)
        #expect(result.outcome == .joined)
    }

    @Test func aTransientRefusalGetsOneMoreTry() async throws {
        let camera = Camera([
            .accepted([Self.result(.failed(4))]), .accepted([Self.result(.joined)]),
        ])
        let result = try await join(camera).run(Self.network)
        #expect(result.outcome == .joined)
        #expect(camera.joins == 2)
    }

    @Test func aWrongPasswordIsNotTriedAgain() async {
        let camera = Camera([.accepted([Self.result(.wrongPassword)])])
        await #expect {
            try await join(camera).run(Self.network)
        } throws: { error in
            (error as? ConnectionFailure)?.code == "com.opencapture.insta360.luna.station.wrong-password"
        }
        #expect(camera.joins == 1)
    }

    @Test func noAnswerGetsOneMoreTryThenTimesOut() async throws {
        let clock = ManualHostClock()
        let camera = Camera([.accepted([]), .accepted([])])
        let outcome = await finish(join(camera, clock: clock), clock: clock, step: .seconds(45))
        #expect((outcome.failure as? ConnectionFailure)?.code == "com.opencapture.insta360.luna.station.join-timeout")
        #expect(camera.joins == 2)
    }

    @Test func aSetupWithoutAPasswordThatFailsSaysToCheckThePassword() async {
        let open = LunaStationNetwork(ssid: "Studio", password: "", hotspot: false)
        let camera = Camera([.accepted([Self.result(.failed(2), password: "")]), .accepted([Self.result(.failed(2), password: "")])])
        do {
            _ = try await join(camera).run(open)
            Issue.record("a refused join must fail")
        } catch let failure as ConnectionFailure {
            #expect(failure.code == "com.opencapture.insta360.luna.station.check-password")
            #expect(failure.message.contains("Check the Wi-Fi password"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
