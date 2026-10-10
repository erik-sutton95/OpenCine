import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED actual protocol descriptors and manual continuation clock; no sleeps or camera.
@Suite @MainActor
struct DJIAppleImageControlTests {
    private final class Endpoint {}
    @MainActor private final class FormatPeer {
        let endpoint = Endpoint()
        let successor = Endpoint()
        var binding: DjiAppleSettingsBinding
        var status = CameraStatus()
        var browsing = false
        var pinned = false
        var time: TimeInterval = 0
        var formats: [VideoFormat] = []
        var enables = 0
        var waits: [(Duration, CheckedContinuation<Void, any Error>)] = []
        var observer: ((DjiAppleFirstPictureFormat.Event) -> Void)?
        lazy var owner = DjiAppleFirstPictureFormat(
            binding: { [unowned self] in binding },
            facts: { [unowned self] in
                .init(status: status, browsing: browsing, formatPinned: pinned)
            },
            setFormat: { [unowned self] in formats.append($0) },
            enable: { [unowned self] in enables += 1 },
            timing: .init(
                now: { [unowned self] in Date(timeIntervalSinceReferenceDate: time) },
                wait: { [unowned self] duration in
                    try await withCheckedThrowingContinuation { waits.append((duration, $0)) }
                }), event: { [unowned self] in observer?($0) })
        init() { binding = .init() }
        func settle() async { for _ in 0..<50 { await Task.yield() } }
        func advance(_ seconds: TimeInterval) async {
            time += seconds
            if !waits.isEmpty { waits.removeFirst().1.resume() }
            await settle()
        }
        func finish() async {
            owner.reset()
            let captured = waits
            waits.removeAll()
            for wait in captured { wait.1.resume(throwing: CancellationError()) }
            await settle()
        }
    }
    @MainActor private final class ZoomPeer {
        let endpoint = Endpoint()
        let successor = Endpoint()
        var binding: DjiAppleSettingsBinding
        var status = CameraStatus()
        var previewing = false
        var locked = false
        var supports = true
        var time: TimeInterval = 0
        var requests: [DjiAppleControlExchange.SetRequest] = []
        var callbacks: [@MainActor (DjiAppleControlExchange.SetEvent) -> Void] = []
        var events: [DjiAppleZoomColor.Event] = []
        var observer: ((DjiAppleZoomColor.Event) -> Void)?
        var inlineSend:
            (
                (
                    DjiAppleControlExchange.SetRequest,
                    @escaping @MainActor (DjiAppleControlExchange.SetEvent) -> Void
                ) -> Void
            )?
        lazy var owner = DjiAppleZoomColor(
            binding: { [unowned self] in binding },
            facts: { [unowned self] in
                .init(
                    status: status, model: nil, supportsZoom: supports,
                    previewing: previewing, locked: locked)
            },
            send: { [unowned self] request, completion in
                requests.append(request)
                callbacks.append(completion)
                inlineSend?(request, completion)
            },
            now: { [unowned self] in Date(timeIntervalSinceReferenceDate: time) },
            event: { [unowned self] value in
                events.append(value)
                if case .flushed = value { previewing = true }
                observer?(value)
            })
        init() {
            binding = .init()
            status.colorMode = .dLog2
        }
    }

    @Test func formatKickRestoreAndEnableUseCapturedRecipeAndBothMinimumSettles() async {
        let p = FormatPeer()
        let original = VideoFormat.firstPictureOriginal(format: nil, resolution: nil, fps: 0)
        let kick = VideoFormat.firstPictureEncoderKick(from: original, available: [])
        p.owner.start()
        await p.settle()
        #expect(p.formats == [kick] && p.enables == 0)
        #expect(p.owner.snapshot.poked && p.owner.snapshot.running)
        #expect(p.waits.first?.0 == .seconds(0.8))
        await p.advance(0.8)
        #expect(p.formats == [kick, original] && p.enables == 0)
        #expect(p.waits.first?.0 == .seconds(0.8))
        await p.advance(0.8)
        #expect(p.enables == 1 && !p.owner.snapshot.running)
        await p.finish()
    }

    @Test func formatPinWaitUsesFiftyMillisecondsAndOriginalTwoSecondCeiling() async {
        let p = FormatPeer()
        p.pinned = true
        p.owner.start()
        await p.settle()
        #expect(p.waits.first?.0 == .milliseconds(50) && p.formats.count == 1)
        await p.advance(2)
        #expect(p.formats.count == 2 && p.enables == 0)
        #expect(p.waits.first?.0 == .milliseconds(50))
        p.pinned = false
        await p.advance(0.05)
        #expect(p.waits.count == 1 && p.formats.count == 2)
        await p.advance(0.75)
        #expect(p.enables == 1)
        await p.finish()
    }

    @Test func formatInitialRecordingAndGalleryRefuseWithoutManufacturingPoked() async {
        for recording in [false, true] {
            let p = FormatPeer()
            p.status.isRecording = recording
            p.browsing = !recording
            p.owner.start()
            await p.settle()
            #expect(p.formats.isEmpty && !p.owner.snapshot.poked && !p.owner.snapshot.running)
            await p.finish()
        }
    }

    @Test func nilDriverRetainsOriginalAttemptButReplacementCannotRestoreOrEnable() async {
        let p = FormatPeer()
        p.owner.start()
        await p.settle()
        #expect(p.binding.endpoint == nil && p.formats.count == 1)
        p.binding = .init(endpoint: ObjectIdentifier(p.successor), controlGeneration: 1)
        await p.advance(0.8)
        #expect(p.formats.count == 1 && p.enables == 0)
        await p.finish()
    }

    @Test func resetAtEitherWaitRetiresOnlyOutgoingTaskAndDoesNotSendRestore() async {
        for first in [true, false] {
            let p = FormatPeer()
            p.owner.start()
            await p.settle()
            if !first { await p.advance(0.8) }
            let count = p.formats.count
            p.owner.reset()
            await p.advance(0.8)
            #expect(p.formats.count == count && p.enables == 0 && !p.owner.snapshot.poked)
            await p.finish()
        }
    }

    @Test func galleryCoverDuringWaitKeepsCapturedRestoreButRefusesEnable() async {
        let p = FormatPeer()
        p.owner.start()
        await p.settle()
        p.browsing = true
        await p.advance(0.8)
        #expect(p.formats.count == 2)
        await p.advance(0.8)
        #expect(p.enables == 0)
        await p.finish()
    }

    @Test func preparingReentryAndCommittedPokedNotificationCannotSendOutgoingFormat() async {
        for preparing in [false, true] {
            let p = FormatPeer()
            p.observer = { event in
                if preparing, case .preparing = event { p.owner.reset() }
                if !preparing, case .changed(let snapshot, _) = event, snapshot.poked {
                    p.owner.reset()
                }
            }
            p.owner.start()
            await p.settle()
            #expect(p.formats.isEmpty && p.enables == 0 && !p.owner.snapshot.poked)
            p.observer = nil
            await p.finish()
        }
    }

    @Test func colorAcknowledgementCannotReleaseQueuedLensBeforeActualDLogReport() {
        let p = ZoomPeer()
        p.owner.slider(3)
        #expect(
            p.requests.count == 1 && p.requests[0].frame == Commands.setColorMode(.dLog, model: nil)
        )
        #expect(p.owner.snapshot.hopPending && p.owner.snapshot.pendingFactor == 3)
        p.callbacks[0](.settled(true))
        #expect(p.requests.count == 1 && p.owner.snapshot.hopPending)
        p.status.colorMode = .dLog
        p.owner.confirmIfReady()
        #expect(
            p.requests.count == 2 && !p.owner.snapshot.hopPending
                && p.owner.snapshot.pendingFactor == nil
        )
        #expect(p.requests[1].frame == Commands.setZoomLens(CamFov.pinchLens(for: 3)))
        #expect(
            !p.requests[1].retransmits && p.requests[1].coalesce && p.requests[1].expectation == nil
        )
    }

    @Test func latestPendingStageAccountingCannotOverwriteCallbackCreatedSuccessor() {
        let p = ZoomPeer()
        var canceled: [String] = []
        p.owner.slider(
            2,
            onStage: { value in
                if case .notSent = value {
                    canceled.append("first")
                    p.owner.queue(4, onStage: nil)
                }
            })
        p.owner.queue(
            3, onStage: { value in if case .notSent = value { canceled.append("second") } })
        #expect(p.owner.snapshot.pendingFactor == 4 && canceled == ["first", "second"])
        p.status.colorMode = .dLog
        p.owner.confirmIfReady()
        #expect(p.requests.last?.frame == Commands.setZoomLens(CamFov.pinchLens(for: 4)))
    }

    @Test func exactTwoSecondRetryRejectsOldColorFailureAndKeepsSuccessorPending() {
        let p = ZoomPeer()
        p.owner.slider(2)
        p.time = 1.999
        p.owner.slider(3)
        #expect(p.requests.count == 1)
        p.time = 2
        p.owner.slider(4)
        #expect(
            p.requests.count == 2 && p.owner.snapshot.hopPending
                && p.owner.snapshot.pendingFactor == 4)
        p.callbacks[0](.failed)
        p.callbacks[0](.settled(false))
        #expect(
            p.owner.snapshot.hopPending && p.owner.snapshot.restoreOnWide
                && p.owner.snapshot.pendingFactor == 4)
    }

    @Test func failureAndNegativeSettlementPreserveOriginalRestoreFlagDistinction() {
        for failure in [false, true] {
            let p = ZoomPeer()
            p.owner.slider(3)
            if failure { p.callbacks[0](.failed) } else { p.callbacks[0](.settled(false)) }
            #expect(!p.owner.snapshot.hopPending && p.owner.snapshot.restoreOnWide == !failure)
            #expect(p.requests.count == 1)
        }
    }

    @Test func recordingBlockAndManualDLog2RetireOldHopWithoutInventingDLogReport() {
        let p = ZoomPeer()
        p.status.isRecording = true
        p.owner.slider(3)
        #expect(p.requests.isEmpty && !p.owner.snapshot.hopPending)
        p.status.isRecording = false
        p.owner.slider(3)
        p.owner.manualColorSelected(.dLog2)
        p.callbacks[0](.settled(true))
        #expect(
            !p.owner.snapshot.hopPending && p.requests.count == 1 && p.status.colorMode == .dLog2)
    }

    @Test func programmedZoomRetiresPendingExactlyOnceAndDisablesWideRestore() {
        let p = ZoomPeer()
        var count = 0
        p.owner.slider(3, onStage: { value in if case .notSent = value { count += 1 } })
        p.owner.retireForProgrammedZoom()
        p.owner.retireForProgrammedZoom()
        p.status.colorMode = .dLog
        p.owner.confirmIfReady()
        p.owner.restoreIfNeeded(afterZoom: 1)
        #expect(count == 1 && p.requests.count == 1 && !p.owner.snapshot.restoreOnWide)
    }

    @Test func parkedWideRestoreUsesOriginalColorDescriptorAndRecordingAdmission() {
        let p = ZoomPeer()
        p.owner.slider(3)
        p.status.colorMode = .dLog
        p.owner.confirmIfReady()
        p.owner.restoreIfNeeded(afterZoom: 3)
        #expect(p.requests.count == 2)
        p.status.isRecording = true
        p.owner.restoreIfNeeded(afterZoom: 1)
        #expect(p.requests.count == 2 && p.owner.snapshot.restoreOnWide)
        p.status.isRecording = false
        p.owner.restoreIfNeeded(afterZoom: 1)
        #expect(p.requests.count == 3 && !p.owner.snapshot.restoreOnWide)
        #expect(p.requests[2].frame == Commands.setColorMode(.dLog2, model: nil))
    }

    @Test func replacedTransportCannotConfirmOldHopOrReleaseCapturedPendingLens() {
        let p = ZoomPeer()
        p.binding = .init(endpoint: ObjectIdentifier(p.endpoint), controlGeneration: 1)
        p.owner.slider(3)
        p.binding = .init(endpoint: ObjectIdentifier(p.successor), controlGeneration: 2)
        p.status.colorMode = .dLog
        p.callbacks[0](.settled(true))
        p.owner.confirmIfReady()
        #expect(p.requests.count == 1 && p.owner.snapshot.pendingFactor == 3)
        p.owner.reset()
        #expect(p.requests.count == 1 && p.owner.snapshot == .init())
    }

    @Test func confirmedNotificationReentryAndPreparedHopCannotSendOutgoingWrite() {
        for confirmed in [false, true] {
            let p = ZoomPeer()
            if confirmed {
                p.owner.slider(3)
                p.status.colorMode = .dLog
                p.observer = { value in if case .confirmed = value { p.owner.reset() } }
                p.owner.confirmIfReady()
                #expect(p.requests.count == 1)
            } else {
                p.observer = { value in if case .hopPreparing = value { p.owner.reset() } }
                p.owner.slider(3)
                #expect(p.requests.isEmpty)
            }
            #expect(p.owner.snapshot == .init())
        }
    }

    @Test func nativeZoomDescriptorOptionsRemainOriginalForChipSlewAndUnsupported() {
        let p = ZoomPeer()
        p.status.colorMode = .normal
        p.owner.fire(.lens(7), target: 3, announce: true)
        p.owner.fire(.slew(CamFov.slewTele), target: nil, announce: false)
        #expect(p.requests.count == 2)
        #expect(
            p.requests[0].frame == Commands.setZoomLens(7) && p.requests[0].retransmits
                && !p.requests[0].coalesce)
        #expect(p.requests[0].name == "Zoom 3×")
        #expect(
            p.requests[1].frame == Commands.setZoomSlew(CamFov.slewTele)
                && p.requests[1].name == "Zoom 1×")
        #expect(!p.requests[1].retransmits && p.requests[1].coalesce)
        var canceled = false
        p.supports = false
        p.owner.fire(
            .lens(8), target: nil, announce: false,
            onStage: { value in if case .notSent = value { canceled = true } })
        #expect(canceled && p.requests.count == 2)
    }

    @Test func discardedStageReentryRetainsSuccessorAndRejectsOutgoingPresentationCleanup() {
        let p = ZoomPeer()
        p.owner.slider(
            2,
            onStage: { value in
                if case .notSent = value { p.owner.queue(4, onStage: nil) }
            })
        let accepted = p.owner.discardPending()
        #expect(!accepted && p.owner.snapshot.pendingFactor == 4)
        p.status.colorMode = .dLog
        p.owner.confirmIfReady()
        #expect(p.requests.last?.frame == Commands.setZoomLens(CamFov.pinchLens(for: 4)))
    }

    @Test func programmedRetirementStageReentryKeepsNewRequestAndRejectsOutgoingStart() {
        let p = ZoomPeer()
        p.owner.slider(
            2,
            onStage: { value in
                if case .notSent = value { p.owner.queue(4, onStage: nil) }
            })
        #expect(!p.owner.retireForProgrammedZoom())
        #expect(p.owner.snapshot.pendingFactor == 4 && !p.owner.snapshot.restoreOnWide)
    }

    @Test func manualWireInvocationInvalidatesCapturedPresentationWithoutRetiringColorGeneration() {
        let p = ZoomPeer()
        p.status.colorMode = .normal
        let captured = p.owner.authority
        p.owner.fire(.lens(5), target: nil, announce: false)
        #expect(!p.owner.admits(captured) && p.requests.count == 1)
        p.status.colorMode = .dLog2
        p.owner.slider(2)
        p.owner.slider(4)
        p.status.colorMode = .dLog
        p.callbacks[1](.settled(true))
        #expect(p.requests.last?.frame == Commands.setZoomLens(CamFov.pinchLens(for: 4)))
    }

    @Test func synchronousActualDLogSuccessAdmitsLatestSliderAfterOwnedConfirmation() {
        let p = ZoomPeer()
        var notSent = 0
        p.inlineSend = { request, completion in
            if request.name == "D-Log (zoom)" {
                p.status.colorMode = .dLog
                completion(.settled(true))
            }
        }
        p.owner.slider(3, onStage: { value in if case .notSent = value { notSent += 1 } })
        #expect(p.requests.count == 2 && notSent == 0 && !p.owner.snapshot.hopPending)
        #expect(p.requests[1].frame == Commands.setZoomLens(CamFov.pinchLens(for: 3)))
        #expect(p.owner.snapshot.pendingFactor == nil && p.status.colorMode == .dLog)
    }

    @Test func synchronousOwnedConfirmationFlushesPreviousThenAdmitsLatestDonorSlider() {
        let p = ZoomPeer()
        var previousNotSent = 0
        var latestNotSent = 0
        p.owner.slider(2, onStage: { value in if case .notSent = value { previousNotSent += 1 } })
        p.time = 2
        p.inlineSend = { request, completion in
            if request.name == "D-Log (zoom)" {
                p.status.colorMode = .dLog
                completion(.settled(true))
            }
        }
        p.owner.slider(4, onStage: { value in if case .notSent = value { latestNotSent += 1 } })
        #expect(p.requests.count == 4 && previousNotSent == 0 && latestNotSent == 0)
        #expect(p.requests[2].frame == Commands.setZoomLens(CamFov.pinchLens(for: 2)))
        #expect(p.requests[3].frame == Commands.setZoomLens(CamFov.pinchLens(for: 4)))
        #expect(p.owner.snapshot.pendingFactor == nil && !p.owner.snapshot.hopPending)
    }

    @Test
    func synchronousConfirmationCallbackSuccessorRejectsOutgoingSliderWithoutRecapturingAuthority()
    {
        let p = ZoomPeer()
        var outgoingNotSent = 0
        p.inlineSend = { request, completion in
            if request.name == "D-Log (zoom)" {
                p.status.colorMode = .dLog
                completion(.settled(true))
            }
        }
        p.observer = { event in
            if case .confirmed = event {
                p.observer = nil
                p.owner.slider(4)
            }
        }
        p.owner.slider(3, onStage: { value in if case .notSent = value { outgoingNotSent += 1 } })
        #expect(p.requests.count == 2 && outgoingNotSent == 1)
        #expect(p.requests[1].frame == Commands.setZoomLens(CamFov.pinchLens(for: 4)))
        #expect(!p.requests.contains { $0.frame == Commands.setZoomLens(CamFov.pinchLens(for: 3)) })
    }

}
