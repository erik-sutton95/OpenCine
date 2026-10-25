import Foundation
import OpenCineCore
import Testing

@testable import OpenCineNikon

/// Hardware pass 4.1 (Nikon ZR, two phones): the phone that lost the camera to a take-over kept
/// its old live-view ladder running. The ladder restarted live view on the dead link and then
/// asked the app to reconnect in place (`.reconnectReady`), a dial that skips the shared recovery
/// episode and its take-over check. The phone showed "Camera taken over" while it took the camera
/// back three seconds later, and the body hung after the repeated hand-overs. A link that has
/// streamed and then fails hands the decision to recovery (`.recover`), the one dialer that asks
/// who holds the camera first.
@MainActor
@Suite("Nikon preview ladder after a take-over", .timeLimit(.minutes(1)))
struct NikonMonitorRuntimeTakeOverTests {
    @Test("A link the camera closed after streaming escalates to recovery and never redials")
    func closedLinkRecoversWithoutRedial() async {
        let link = ScriptedLink(frames: [.frame, .fail(NativeCameraSessionError.connectionClosed)])
        link.startFailure = NativeCameraSessionError.connectionClosed
        link.startFailureFromCall = 2
        let events = await run(link)
        #expect(events.last == "recover", "events: \(events)")
        #expect(!events.contains("reconnect-ready"), "events: \(events)")
        #expect(!events.contains("restart"), "events: \(events)")
        // Nothing more goes to a body that dropped this phone: no EndLiveView, no new start.
        #expect(link.stops == 0)
        #expect(link.starts == 1)
    }

    @Test("A streamed link whose live view cannot restart escalates to recovery, not a dial")
    func refusedRestartRecoversWithoutRedial() async {
        let link = ScriptedLink(frames: [.frame, .fail(NativeCameraSessionError.timeout("frame"))])
        link.startFailure = NativeCameraSessionError.operationRejected(.startLiveView, .deviceBusy)
        link.startFailureFromCall = 2
        let events = await run(link)
        #expect(events.contains("restart"), "events: \(events)")
        #expect(events.last == "recover", "events: \(events)")
        #expect(!events.contains("reconnect-ready"), "events: \(events)")
    }

    @Test("A fresh session whose live view never started keeps its in-place reconnect")
    func freshSessionKeepsInPlaceReconnect() async {
        let link = ScriptedLink(frames: [])
        link.startFailure = NativeCameraSessionError.operationRejected(.startLiveView, .deviceBusy)
        let events = await run(link)
        #expect(events.last == "reconnect-ready", "events: \(events)")
    }

    /// Runs the preview until it hands a decision to the app, with every ladder delay instant.
    /// Waits on the events themselves, not a wall clock: a loaded CI host can park the main actor
    /// for longer than any fixed deadline (the suite's time limit bounds a real hang).
    private func run(_ link: ScriptedLink) async -> [String] {
        let runtime = NikonMonitorRuntime(link: link, backgroundSleep: { _ in await Task.yield() })
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        runtime.startPreview(
            bootstrap: {},
            demand: { .init(mode: .picture, size: 2, compression: 1) },
            consume: { _, _ in true }, safePoint: { _, _ in },
            applied: { _ in }, resetCadence: {}, health: { _ in },
            event: { event in
                switch event {
                case .opening: continuation.yield("opening")
                case .restart: continuation.yield("restart")
                case .reconnect: continuation.yield("reconnect")
                case .reconnectReady:
                    continuation.yield("reconnect-ready")
                    continuation.finish()
                case .recover:
                    continuation.yield("recover")
                    continuation.finish()
                }
            })
        var events: [String] = []
        for await event in stream { events.append(event) }
        runtime.retirePumps()
        return events
    }
}

@MainActor
private final class ScriptedLink: NikonMonitorLink {
    enum Step {
        case frame
        case fail(Error)
    }

    let serialNumber = "3000123"
    private var frames: [Step]
    var startFailure: Error?
    /// The first `startLiveView` call (1-based) that fails with `startFailure`.
    var startFailureFromCall = 1
    private(set) var starts = 0
    private(set) var stops = 0

    init(frames: [Step]) { self.frames = frames }

    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func configureLiveView(size: UInt8, compression: UInt8) async {}
    func startLiveView() async throws {
        starts += 1
        if let startFailure, starts >= startFailureFromCall { throw startFailure }
    }
    func stopLiveView() async { stops += 1 }
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        let step = frames.isEmpty ? .fail(NativeCameraSessionError.connectionClosed) : frames.removeFirst()
        switch step {
        case .frame:
            return PTPLiveViewFrame(
                jpeg: Data([1, 2, 3]),
                timecode: Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0))
        case .fail(let error):
            throw error
        }
    }
    func readLastCommandRoundTripMilliseconds() -> Double? { nil }
    func sendKeepAlive() async throws {}
    func nextEvent() async throws -> PTPEvent { throw NativeCameraSessionError.connectionClosed }
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness {
        throw NativeCameraSessionError.connectionClosed
    }
    func shutdown() async {}
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {}
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data { Data() }
    func startRecording() async throws {}
    func stopRecording() async throws {}
}
