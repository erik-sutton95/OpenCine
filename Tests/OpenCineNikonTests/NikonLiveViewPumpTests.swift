import Foundation
import Testing

@testable import OpenCineNikon

@MainActor
@Suite("Nikon integration-owned preview pump")
struct NikonLiveViewPumpTests {
    @Test("A short cover drains its kept fetch and keeps the stream warm without a restart")
    func shortCover() async {
        let link = PreviewLink()
        var mode: NikonPreviewDemand.Mode = .picture
        var alive = true
        var ticks = 0
        let pump = NikonLiveViewPump(link: link, sleep: { _ in })
        let outcome = await pump.run(
            demand: { NikonPreviewDemand(mode: mode, size: 2, compression: 1) },
            isCurrent: { alive },
            consume: { _, delivery in
                if delivery.first { mode = .covered } else { alive = false }
                return true
            },
            safePoint: { _, poll in
                #expect(poll)
                ticks += 1
                mode = .picture
            })
        await pump.drain()
        #expect(outcome == .cancelled)
        #expect(ticks == 1)
        #expect(link.starts == 1)
        #expect(link.stops == 0)
        #expect(link.deadlines.contains(.seconds(2)))
        #expect(link.deadlines.filter { $0 == .seconds(10) }.count == 2)
        #expect(!link.fetchWasCancelled)
    }

    @Test("A long cover ends live view once and resumes with the first-frame deadline")
    func longCover() async {
        let link = PreviewLink()
        var now = Date(timeIntervalSince1970: 0)
        var mode: NikonPreviewDemand.Mode = .picture
        var alive = true
        var ticks = 0
        let pump = NikonLiveViewPump(link: link, now: { now }, sleep: { _ in now += 16 })
        _ = await pump.run(
            demand: { NikonPreviewDemand(mode: mode, size: 2, compression: 1) },
            isCurrent: { alive },
            consume: { _, delivery in
                if delivery.first { mode = .covered } else { alive = false }
                return true
            },
            safePoint: { _, _ in
                ticks += 1
                if ticks == 3 { mode = .picture }
            })
        await pump.drain()
        #expect(link.stops == 1)
        #expect(link.starts == 2)
        #expect(!link.fetchWasCancelled)
        #expect(link.deadlines.filter { $0 == .seconds(10) }.count == 2)
    }

    @Test("Command display consumes headers without picture decode and drains the old fetch")
    func headerDisplay() async {
        let link = PreviewLink()
        var mode: NikonPreviewDemand.Mode = .picture
        var alive = true
        var picture = 0
        var headers = 0
        let pump = NikonLiveViewPump(link: link)
        _ = await pump.run(
            demand: { NikonPreviewDemand(mode: mode, size: 0, compression: 1) },
            isCurrent: { alive },
            consume: { _, delivery in
                if delivery.headerOnly {
                    headers += 1
                    alive = false
                } else {
                    picture += 1
                    mode = .headerOnly
                }
                return true
            }, safePoint: { _, _ in })
        await pump.drain()
        #expect(picture == 1)
        #expect(headers == 1)
        #expect(link.stops == 1)
        #expect(link.starts == 2)
        #expect(!link.fetchWasCancelled)
    }

    @Test("Command-mode entry validates one picture before switching to header-only pulls")
    func commandModeEntryKeepsDonorStartup() async {
        let link = PreviewLink()
        var alive = true
        var pictures = 0
        var headers = 0
        let pump = NikonLiveViewPump(link: link, sleep: { _ in })
        _ = await pump.run(
            demand: { NikonPreviewDemand(mode: .headerOnly, size: 0, compression: 1) },
            isCurrent: { alive },
            consume: { _, delivery in
                if delivery.first {
                    #expect(!delivery.headerOnly)
                    pictures += 1
                } else {
                    #expect(delivery.headerOnly)
                    headers += 1
                    alive = false
                }
                return true
            }, safePoint: { _, _ in })
        await pump.drain()
        #expect(pictures == 1)
        #expect(headers == 1)
        #expect(link.starts == 2)
        #expect(link.stops == 1)
        #expect(!link.fetchWasCancelled)
    }

    @Test("HDMI control-only mode carries headers and keeps its own picture untouched")
    func controlOnly() async {
        let link = PreviewLink()
        var alive = true
        var headers = 0
        let pump = NikonLiveViewPump(link: link, sleep: { _ in })
        _ = await pump.run(
            demand: { NikonPreviewDemand(mode: .controlOnly, size: 0, compression: 1) },
            isCurrent: { alive },
            consume: { _, delivery in
                #expect(delivery.headerOnly)
                #expect(!delivery.first)
                headers += 1
                return true
            },
            safePoint: { count, poll in
                #expect(!poll)
                if count == 2 { alive = false }
            })
        await pump.drain()
        #expect(headers == 2)
        #expect(link.starts == 1)
        #expect(link.stops == 0)
        #expect(link.deadlines == [.seconds(6), .seconds(6)])
    }

    @Test("A fetch completing after retirement never reaches its old consumer")
    func lateBorrowedFetch() async {
        let link = PreviewLink()
        link.holdFetch = true
        var alive = true
        var delivered = 0
        let pump = NikonLiveViewPump(link: link)
        let run = Task {
            await pump.run(
                demand: { NikonPreviewDemand(mode: .picture, size: 2, compression: 1) },
                isCurrent: { alive },
                consume: { _, _ in
                    delivered += 1
                    return true
                },
                safePoint: { _, _ in })
        }
        await link.waitForHeldFetch()
        alive = false
        run.cancel()
        link.releaseFetch()
        #expect(await run.value == .cancelled)
        await pump.drain()
        #expect(delivered == 0)
        #expect(!link.fetchWasCancelled)
        #expect(link.stops == 0)
    }
}

@MainActor
private final class PreviewLink: NikonMonitorLink {
    let serialNumber = "SIMULATED"
    var starts = 0
    var stops = 0
    var deadlines: [Duration] = []
    var fetchWasCancelled = false
    var holdFetch = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func supportsProperty(_ property: PTPPropertyCode) -> Bool { true }
    func configureLiveView(size: UInt8, compression: UInt8) async {}
    func startLiveView() async throws { starts += 1 }
    func stopLiveView() async { stops += 1 }
    func liveViewFrame(deadline: Duration?) async throws -> PTPLiveViewFrame {
        if let deadline { deadlines.append(deadline) }
        if holdFetch {
            await withCheckedContinuation {
                held = $0
                waiter?.resume()
                waiter = nil
            }
        }
        fetchWasCancelled = fetchWasCancelled || Task.isCancelled
        return PTPLiveViewFrame(
            jpeg: Data([1, 2, UInt8(deadlines.count)]),
            timecode: Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0))
    }
    func waitForHeldFetch() async {
        if held == nil { await withCheckedContinuation { waiter = $0 } }
    }
    func releaseFetch() {
        held?.resume()
        held = nil
    }
    func readLastCommandRoundTripMilliseconds() -> Double? { nil }
    func sendKeepAlive() async throws {}
    func nextEvent() async throws -> PTPEvent { throw NativeCameraSessionError.connectionClosed }
    func pollStillReleaseReadiness() async throws -> StillReleaseReadiness { .complete }
    func shutdown() async {}
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws {}
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data { Data() }
    func startRecording() async throws {}
    func stopRecording() async throws {}
}
