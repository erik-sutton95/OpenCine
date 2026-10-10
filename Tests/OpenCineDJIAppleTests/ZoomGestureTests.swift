import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED actual composed gesture/color owners; manual time and synchronous wire callbacks.
@Suite @MainActor
struct DJIAppleZoomGestureTests {
    private final class Endpoint {}
    @MainActor private final class Peer {
        let endpoint = Endpoint()
        let replacement = Endpoint()
        var binding = DjiAppleSettingsBinding()
        var status = CameraStatus()
        var time: TimeInterval = 0
        var supports = true
        var locked = false
        var stops = CamFov.jumps
        var requests: [DjiAppleControlExchange.SetRequest] = []
        var callbacks: [@MainActor (DjiAppleControlExchange.SetEvent) -> Void] = []
        var stopFrames: [Duml.Frame] = []
        var stopCallbacks: [@MainActor (Bool) -> Void] = []
        var observer: ((DjiAppleZoomGesture.Event) -> Void)?
        var colorObserver: ((DjiAppleZoomColor.Event) -> Void)?
        lazy var color: DjiAppleZoomColor = DjiAppleZoomColor(
            binding: { [unowned self] in binding },
            facts: { [unowned self] in
                .init(
                    status: status, model: nil, supportsZoom: supports,
                    previewing: gesture.snapshot.preview != nil, locked: locked)
            },
            send: { [unowned self] request, callback in
                requests.append(request)
                callbacks.append(callback)
            }, now: { [unowned self] in Date(timeIntervalSinceReferenceDate: time) },
            event: { [unowned self] event in
                if case .flushed(let factor) = event { _ = gesture.flushed(factor) }
                colorObserver?(event)
            })
        lazy var gesture: DjiAppleZoomGesture = DjiAppleZoomGesture(
            binding: { [unowned self] in binding },
            facts: { [unowned self] in
                .init(status: status, stops: stops, supportsZoom: supports, locked: locked)
            }, color: color, now: { [unowned self] in time },
            sendStop: { [unowned self] frame, callback in
                stopFrames.append(frame)
                stopCallbacks.append(callback)
            }, event: { [unowned self] in observer?($0) })
        init() {
            binding.endpoint = ObjectIdentifier(endpoint)
            status.colorMode = .dLog
            status.zoomFactorRaw = CamFov.rawAt1x
        }
    }

    @Test func firstUnchangedPinchAndDuplicateLensDoNotSendButNextTickDoes() {
        let p = Peer()
        p.gesture.updatePinch(magnification: 1)
        #expect(p.requests.isEmpty && p.gesture.snapshot.preview == 1)
        p.gesture.updatePinch(magnification: 2)
        #expect(p.requests.count == 1 && p.gesture.snapshot.preview == 2)
        p.gesture.updatePinch(magnification: 2)
        #expect(p.requests.count == 1)
        p.gesture.updatePinch(magnification: 2.01)
        #expect(p.requests.count == 2)
    }
    @Test func liveTelemetryDoesNotReanchorCurrentGestureAndLiftKeepsLastStop() {
        let p = Peer()
        p.gesture.updatePinch(magnification: 2)
        p.status.zoomFactorRaw = CamFov.rawAt3x
        p.gesture.observe(p.status)
        p.gesture.updatePinch(magnification: 3)
        #expect(p.gesture.snapshot.preview == 3)
        p.gesture.endPinch()
        #expect(p.gesture.snapshot.preview == nil && p.gesture.snapshot.stop == 3)
    }
    @Test func chipProjectionExpiresAtExactTwoSecondsEvenWhenTelemetryBytesRepeat() {
        let p = Peer()
        p.gesture.chip(3)
        #expect(p.gesture.snapshot.optimistic == 3 && p.gesture.readout == 3)
        p.time = 1.999
        p.gesture.observe(p.status)
        #expect(p.gesture.snapshot.optimistic == 3)
        p.time = 2
        p.gesture.observe(p.status)
        #expect(p.gesture.snapshot.optimistic == nil && p.gesture.readout == 1)
    }
    @Test func actualLensConfirmationReleasesPinAndFormatCeilingLimitsOnlyFallback() {
        let p = Peer()
        p.gesture.chip(3)
        p.status.zoomLens = CamFov.pinchLens(for: 3)
        p.gesture.observe(p.status)
        #expect(p.gesture.snapshot.optimistic == nil && p.gesture.readout == 3)
        p.gesture.chip(12)
        p.time = 2
        p.status.zoomFactorRaw = 0
        p.status.zoomLens = nil
        p.stops = [1, 3]
        p.gesture.observe(p.status)
        #expect(p.gesture.snapshot.stop == 12 && p.gesture.fallback == 3)
    }
    @Test func recordingColorRefusalKeepsUnknownFactsAndDoesNotPresentPinch() {
        let p = Peer()
        p.status.colorMode = .dLog2
        p.status.isRecording = true
        p.gesture.updatePinch(magnification: 3)
        #expect(p.gesture.snapshot.preview == nil && p.requests.isEmpty)
        var notSent = 0
        p.gesture.chip(3, onStage: { if case .notSent = $0 { notSent += 1 } })
        #expect(notSent == 1 && p.requests.isEmpty && p.status.colorMode == .dLog2)
    }
    @Test func committedPreviewObserverReentryCannotSendOutgoingLensOrClearSuccessorPin() {
        let p = Peer()
        var replaced = false
        p.observer = { event in
            if case .changed(_, let next, _) = event, next.preview == 2, !replaced {
                replaced = true
                p.gesture.chip(6)
            }
        }
        p.gesture.updatePinch(magnification: 2)
        #expect(replaced && p.requests.count == 1)
        #expect(p.gesture.snapshot.preview == nil && p.gesture.snapshot.optimistic == 6)
        #expect(p.requests[0].frame.payload == Commands.setZoomLens(CamFov.lens6x).payload)
    }
    @Test func identicalSliderLoggingReentryStillRetiresOutgoingGestureInvocation() {
        let p = Peer()
        var replaced = false
        p.observer = { event in
            if case .sliderRequested = event, !replaced {
                replaced = true
                p.gesture.slider(3)
            }
        }
        p.gesture.slider(3)
        #expect(replaced && p.requests.count == 1)
    }
    @Test func transportReplacementBeforeChipNativeEffectRejectsOutgoingWire() {
        let p = Peer()
        p.observer = { event in
            if case .chipPreparing = event {
                p.binding.endpoint = ObjectIdentifier(p.replacement)
            }
        }
        var notSent = 0
        p.gesture.chip(3, onStage: { if case .notSent = $0 { notSent += 1 } })
        #expect(p.requests.isEmpty && notSent == 1)
    }
    @Test func localResetNeverSendsAndRejectsCapturedStopCompletion() {
        let p = Peer()
        var settlements = 0
        p.observer = { if case .stopSettled = $0 { settlements += 1 } }
        p.gesture.stop()
        #expect(p.stopFrames.count == 1 && p.requests.isEmpty)
        p.gesture.reset()
        p.stopCallbacks[0](true)
        #expect(settlements == 0 && p.gesture.snapshot == .init())
    }
    @Test func pendingRetirementCannotClearCallbackCreatedSuccessorGesture() {
        let p = Peer()
        p.status.colorMode = .dLog2
        p.gesture.slider(
            3,
            onStage: { value in
                if case .notSent = value { p.gesture.slider(4) }
            })
        let admitted = p.gesture.retireForProgrammedZoom()
        #expect(!admitted && p.color.snapshot.pendingFactor == 4)
        #expect(p.color.snapshot.hopPending && p.requests.count == 1)
    }

    @Test func nativeZoomPreparingStopReentryCannotSendOutgoingChipAndScopeRestoresDefault() {
        let p = Peer()
        var replaced = false
        p.colorObserver = { event in
            if case .zoomPreparing = event, !replaced {
                replaced = true
                p.gesture.stop()
            }
        }
        var notSent = 0
        p.gesture.chip(3, onStage: { if case .notSent = $0 { notSent += 1 } })
        #expect(replaced && p.stopFrames.count == 1 && p.requests.isEmpty && notSent == 1)
        p.colorObserver = nil
        p.color.fire(.lens(CamFov.lens3x), target: 3, announce: true)
        #expect(p.requests.count == 1)
    }

    @Test func actualIncomingConfirmationAdmitsOwnFlushPublicationAndOriginalQueuedLens() {
        let p = Peer()
        p.status.colorMode = .dLog2
        p.gesture.slider(3)
        #expect(p.requests.count == 1 && p.color.snapshot.pendingFactor == 3)
        p.callbacks[0](.settled(true))
        #expect(p.requests.count == 1 && p.status.colorMode == .dLog2)
        p.status.colorMode = .dLog
        p.gesture.confirmIfReady()
        #expect(p.requests.count == 2 && p.gesture.snapshot.preview == 3)
        #expect(p.color.snapshot.pendingFactor == nil && !p.color.snapshot.hopPending)
    }

    @Test func actualIncomingConfirmationCallbackCreatedStopCannotFlushOldQueuedLens() {
        let p = Peer()
        p.status.colorMode = .dLog2
        p.gesture.slider(3)
        p.status.colorMode = .dLog
        p.colorObserver = { event in
            if case .confirmed = event { p.gesture.stop() }
        }
        p.gesture.confirmIfReady()
        #expect(p.stopFrames.count == 1 && p.requests.count == 1)
        #expect(p.gesture.snapshot.preview == nil && p.status.colorMode == .dLog)
    }

    @Test func directUpdateResetReturnsCommittedAuthorityAndReentrantResetKeepsSuccessor() {
        let p = Peer()
        var committed = 0
        p.observer = { event in
            if case .changed(_, let next, let revision) = event {
                #expect(p.gesture.snapshot == next && p.gesture.revision == revision)
                #expect(p.gesture.admits(p.gesture.authority))
                committed += 1
            }
        }
        p.gesture.reset()
        #expect(committed == 1 && p.gesture.snapshot == .init() && p.requests.isEmpty)
        let resetAuthority = p.gesture.authority
        p.gesture.updatePinch(magnification: 1)
        #expect(p.gesture.snapshot.preview == 1 && p.requests.isEmpty)
        #expect(!p.gesture.admits(resetAuthority) && p.gesture.admits(p.gesture.authority))
        p.gesture.reset()
        #expect(p.gesture.snapshot == .init() && p.gesture.admits(p.gesture.authority))

        let replacement = Peer()
        replacement.status.colorMode = .dLog2
        var reentered = false
        replacement.observer = { event in
            if case .changed(_, let next, _) = event, !reentered {
                #expect(replacement.gesture.snapshot == next && next == .init())
                reentered = true
                replacement.gesture.slider(3)
            }
        }
        replacement.gesture.reset()
        #expect(reentered && replacement.requests.count == 1)
        #expect(replacement.color.snapshot.pendingFactor == 3)
        #expect(replacement.color.snapshot.hopPending)
        #expect(replacement.gesture.admits(replacement.gesture.authority))
    }
}
