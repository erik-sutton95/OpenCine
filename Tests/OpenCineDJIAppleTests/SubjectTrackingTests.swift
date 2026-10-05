import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED actual wire endpoint and manual suspension clock; no sleeps or camera.
@Suite @MainActor
struct DJIAppleSubjectTrackingTests {
    private final class EndpointIdentity {}

    @MainActor private final class Peer {
        let first = EndpointIdentity()
        let second = EndpointIdentity()
        var time: TimeInterval = 0
        var source: DjiAppleTrackingBinding!
        var frames: [(Duml.Frame, String, Bool)] = []
        var acknowledgements: [@MainActor (Bool) -> Void] = []
        var waits: [CheckedContinuation<Void, any Error>] = []
        var observation: ((DjiAppleSubjectTracking.Event) -> Void)?
        lazy var owner = DjiAppleSubjectTracking(
            binding: { [unowned self] in source },
            send: { [unowned self] frame, name, retransmits, settled in
                frames.append((frame, name, retransmits))
                if name == "Track" { acknowledgements.append(settled) }
            },
            timing: .init(
                now: { [unowned self] in Date(timeIntervalSinceReferenceDate: time) },
                wait: { [unowned self] _ in
                    try await withCheckedThrowingContinuation { waits.append($0) }
                }), event: { [unowned self] in observation?($0) })

        init() { source = .init(endpoint: ObjectIdentifier(first), controlGeneration: 1) }

        func settle() async { for _ in 0..<50 { await Task.yield() } }

        func advance(_ duration: TimeInterval) async {
            time += duration
            if !waits.isEmpty { waits.removeFirst().resume() }
            await settle()
        }

        func finish() async {
            owner.stopPolling()
            let pending = waits
            waits.removeAll()
            for wait in pending { wait.resume(throwing: CancellationError()) }
            await settle()
        }
    }

    private let box = TrackingBox(x: 0.2, y: 0.3, width: 0.2, height: 0.3)
    private let live: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x00, 0xA0, 0x41,
        0x85, 0x10, 0x05, 0x3F, 0xC5, 0x4C, 0xC5, 0x3E,
        0xC0, 0x88, 0x3F, 0x3E, 0xCA, 0x30, 0xCA, 0x3E,
    ]

    @Test func actualRequestUsesOriginalCenterSizeAndNoPollBeforeAcknowledgement() async {
        let p = Peer()
        p.owner.start(box)
        #expect(p.frames.count == 1)
        #expect(
            p.frames[0].0
                == Commands.setTrackingBox(
                    id: 1, x: Float(box.centerX),
                    y: Float(box.centerY), width: Float(box.width), height: Float(box.height)))
        #expect(p.frames[0].1 == "Track" && p.frames[0].2)
        #expect(p.owner.snapshot == .init(searchBox: box))
        await p.settle()
        #expect(p.frames.count == 1)
        p.acknowledgements[0](true)
        await p.settle()
        #expect(p.frames.count == 2 && p.frames[1].0 == Commands.pollTracking())
        #expect(p.frames[1].1 == "Track poll" && !p.frames[1].2)
        await p.finish()
    }

    @Test func sixOriginalIdleTicksClearWithoutSendingCameraClear() async {
        let p = Peer()
        p.owner.start(box)
        p.acknowledgements[0](true)
        await p.settle()
        for _ in 0..<5 { await p.advance(0.5) }
        #expect(p.owner.snapshot.searchBox == box)
        await p.advance(0.5)
        #expect(p.owner.snapshot == .init())
        #expect(p.frames.filter { $0.1 == "Track poll" }.count == 6)
        #expect(!p.frames.contains { $0.1 == "Track clear" })
        await p.finish()
    }

    @Test func cameraLockUsesOriginalStandInAndIdleRetiresPoll() async {
        let p = Peer()
        p.owner.start(box)
        p.acknowledgements[0](true)
        await p.settle()
        p.owner.receivePoll([0, 1, 0, 0])
        #expect(
            p.owner.snapshot == .init(subjectBox: TrackingBox.subject(from: box), tracking: true))
        p.owner.receivePoll([0, 0, 0, 0])
        #expect(p.owner.snapshot == .init() && !p.owner.polling)
        let sends = p.frames.count
        await p.advance(0.5)
        #expect(p.frames.count == sends)
        await p.finish()
    }

    @Test func localClearUsesOriginalLeftoverWindowThenCameraTruthAndSilence() async {
        let p = Peer()
        p.owner.receiveLivePush(live)
        await p.settle()
        #expect(p.owner.snapshot.tracking)
        p.owner.cancel(sendClear: true)
        #expect(p.frames.last?.0 == Commands.clearTrackingBox())
        p.time = 0.279
        p.owner.receiveLivePush(live)
        #expect(p.owner.snapshot == .init())
        p.time = 0.28
        p.owner.receiveLivePush(live)
        #expect(p.owner.snapshot.tracking)
        await p.settle()
        // Resume the canceled first wait, then the admitted current polling wait.
        await p.advance(0)
        await p.advance(0.5)
        #expect(p.owner.snapshot == .init())
        await p.finish()
    }

    @Test func oldAcknowledgementAndEndpointCannotStartOrRetireSuccessorPolling() async {
        let p = Peer()
        p.owner.start(box)
        let next = TrackingBox(x: 0.6, y: 0.2, width: 0.15, height: 0.2)
        p.owner.start(next)
        p.acknowledgements[0](true)
        await p.settle()
        #expect(!p.owner.polling && p.frames.count == 2)
        p.acknowledgements[1](true)
        await p.settle()
        let sends = p.frames.count
        p.source = .init(endpoint: ObjectIdentifier(p.second), controlGeneration: 2)
        await p.advance(0.5)
        #expect(p.frames.count == sends && !p.owner.polling)
        #expect(p.owner.snapshot.searchBox == next)
        await p.finish()
    }

    @Test func canceledOldWaitCannotClearNewPollingHandle() async {
        let p = Peer()
        p.owner.start(box)
        p.acknowledgements[0](true)
        await p.settle()
        let next = TrackingBox(x: 0.6, y: 0.2, width: 0.15, height: 0.2)
        p.owner.start(next)
        p.acknowledgements[1](true)
        await p.settle()
        #expect(p.waits.count == 2)
        await p.advance(0)
        #expect(p.owner.polling && p.owner.snapshot.searchBox == next)
        await p.finish()
    }

    @Test func synchronousPublicationSeesCommittedSnapshotAndCancelsBeforeWireSend() async {
        let p = Peer()
        p.observation = { event in
            guard case .changed(_, let next, _) = event, next.searchBox != nil else { return }
            #expect(p.owner.snapshot == next)
            p.owner.cancel(sendClear: false)
        }
        p.owner.start(box)
        #expect(p.owner.snapshot == .init() && p.frames.isEmpty)
        await p.finish()
    }

    @Test func reentrantSmallBoxClearCannotRejectSuccessorOrShowOutgoingWarning() async {
        let p = Peer()
        p.owner.start(box)
        let successor = TrackingBox(x: 0.6, y: 0.2, width: 0.15, height: 0.2)
        var warnings = 0
        p.observation = { event in
            if case .changed(_, let next, _) = event, next == .init() {
                p.owner.start(successor)
            }
            if case .tooSmall = event { warnings += 1 }
        }
        p.owner.start(.init(x: 0.2, y: 0.2, width: 0.02, height: 0.02))
        #expect(p.owner.snapshot.searchBox == successor && warnings == 0)
        #expect(p.frames.count == 2)
        p.observation = nil
        await p.finish()
    }

    @Test func capturedNativePreparationAdmissionRejectsSynchronousReplacement() async {
        let p = Peer()
        let successor = TrackingBox(x: 0.6, y: 0.2, width: 0.15, height: 0.2)
        var outgoingAuthority: DjiAppleSubjectTracking.Authority?
        p.observation = { event in
            guard case .preparing(let authority) = event, p.owner.snapshot.searchBox == box else {
                return
            }
            #expect(p.owner.admits(authority))
            outgoingAuthority = authority
            p.owner.start(successor)
            #expect(!p.owner.admits(authority))
        }
        p.owner.start(box)
        #expect(outgoingAuthority != nil)
        #expect(p.owner.snapshot.searchBox == successor && p.frames.count == 1)
        #expect(
            p.frames[0].0
                == Commands.setTrackingBox(
                    id: 1, x: Float(successor.centerX),
                    y: Float(successor.centerY), width: Float(successor.width),
                    height: Float(successor.height)))
        await p.finish()
    }

    @Test func changedCallbackClearingPublicationCannotPrepareOrSendOutgoingSET() async {
        let p = Peer()
        var preparations = 0
        p.observation = { event in
            if case .changed(_, let next, _) = event, next.searchBox != nil {
                p.owner.rejectSmallBox()
            }
            if case .preparing = event { preparations += 1 }
        }
        p.owner.start(box)
        #expect(p.owner.snapshot == .init() && p.frames.isEmpty && preparations == 0)
        p.observation = nil
        p.owner.start(box)
        #expect(p.frames.count == 1)
        #expect(
            p.frames[0].0
                == Commands.setTrackingBox(
                    id: 1, x: Float(box.centerX),
                    y: Float(box.centerY), width: Float(box.width), height: Float(box.height)))
        await p.finish()
    }

    @Test func preparingCallbackClearingPublicationCannotSendOutgoingSET() async {
        let p = Peer()
        p.observation = { event in
            if case .preparing = event { p.owner.rejectSmallBox() }
        }
        p.owner.start(box)
        #expect(p.owner.snapshot == .init() && p.frames.isEmpty)
        p.observation = nil
        p.owner.start(box)
        #expect(p.frames.count == 1)
        #expect(
            p.frames[0].0
                == Commands.setTrackingBox(
                    id: 1, x: Float(box.centerX),
                    y: Float(box.centerY), width: Float(box.width), height: Float(box.height)))
        await p.finish()
    }

    @Test func unconnectedAndTooSmallPreserveHonestAbsenceAndNoAutomaticCommand() async {
        let p = Peer()
        p.source = .init()
        p.owner.start(box)
        #expect(p.owner.snapshot.searchBox == box && p.frames.isEmpty)
        p.owner.start(.init(x: 0.2, y: 0.2, width: 0.02, height: 0.02))
        #expect(p.owner.snapshot == .init() && p.frames.isEmpty)
        p.owner.reset()
        #expect(p.frames.isEmpty)
        await p.finish()
    }
}
