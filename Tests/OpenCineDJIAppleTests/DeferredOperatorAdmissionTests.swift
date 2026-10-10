import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED actual focus/zoom owners, with manual native decisions and no sleeps.
@MainActor @Suite struct DeferredOperatorAdmissionTests {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isCurrent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return active
        }
        func revoke() {
            lock.lock()
            active = false
            lock.unlock()
        }
    }

    @Test func unavailableSuppliedFocusPortsNeverEnterTheDirectFourWritePath() async {
        let endpoint = NSObject()
        var direct: [Duml.Frame] = []
        let focus = DjiAppleTapFocus(
            binding: { .init(endpoint: ObjectIdentifier(endpoint), controlGeneration: 1) },
            sendPrepare: {
                direct.append($0)
                return 0
            },
            request: { frame, _, _ in
                direct.append(frame)
                return true
            })
        focus.start(
            x: 0.25, y: 0.75,
            admission: .init(owner: DJICommandOwner(), isCurrent: { true }))
        await focus.waitForPending()
        #expect(direct.isEmpty)
        focus.start(x: 0.25, y: 0.75)
        await focus.waitForPending()
        #expect(
            direct == [
                Commands.tapFocusPrepare(), Commands.tapFocusPoint(0.25, 0.75),
                Commands.tapFocusLiveHint(), Commands.tapFocusCommit(0.25, 0.75),
            ])
    }

    @Test func focusCarriesOneReceiptThroughZeroSequencePreparePointHintAndCommit() async {
        let p = FocusPeer()
        let receipt = DJICommandAdmission(owner: p.native, isCurrent: { true })
        p.focus.start(x: 0.25, y: 0.75, admission: receipt)
        await p.focus.waitForPending()
        #expect(p.direct.isEmpty)
        #expect(
            p.frames == [
                Commands.tapFocusPrepare(), Commands.tapFocusPoint(0.25, 0.75),
                Commands.tapFocusLiveHint(), Commands.tapFocusCommit(0.25, 0.75),
            ])
        #expect(p.prepared == [0])
        #expect(p.timeouts == [.milliseconds(800), .milliseconds(800), .milliseconds(800)])
        #expect(p.receipts.allSatisfy { $0.owner === receipt.owner && $0.source == receipt.source })
    }

    @Test func expiryAfterEnteredPointKeepsItsACKButCannotDispatchHintOrCommit() async {
        let p = FocusPeer()
        let gate = Gate()
        p.afterRequest = { gate.revoke() }
        p.focus.start(
            x: 0.25, y: 0.75,
            admission: .init(owner: p.native, isCurrent: { gate.isCurrent }))
        await p.focus.waitForPending()
        #expect(p.frames == [Commands.tapFocusPrepare(), Commands.tapFocusPoint(0.25, 0.75)])
        #expect(p.enteredCompletions == 1)
        #expect(p.direct.isEmpty)
        p.focus.retire()
        #expect(p.frames.count == 2)
    }

    @Test func sourceRetirementAfterPrepareCannotDispatchPointIntoRepeatedEndpoint() async {
        let p = FocusPeer()
        p.afterPrepare = { p.native.replaceSource() }
        p.focus.start(
            x: 0.25, y: 0.75,
            admission: .init(owner: p.native, isCurrent: { true }))
        await p.focus.waitForPending()
        #expect(p.frames == [Commands.tapFocusPrepare()])
        #expect(p.direct.isEmpty)
    }

    @Test func admittedZoomAndItsColorHopKeepTheExactPendingReceiptAndNativeISO() {
        let p = ZoomPeer()
        let receipt = DJICommandAdmission(owner: p.native, isCurrent: { true })
        p.gesture.chip(3, admission: receipt)
        #expect(p.requests.count == 1)
        #expect(p.requests[0].frame == Commands.setColorMode(.dLog, model: nil))
        #expect(p.requests[0].admission?.source == receipt.source)
        #expect(p.isoReceipts.count == 1 && p.isoReceipts[0].source == receipt.source)
        p.status.colorMode = .dLog
        p.gesture.confirmIfReady()
        #expect(p.requests.count == 2)
        #expect(p.requests[1].frame == Commands.setZoomLens(CamFov.pinchLens(for: 3)))
        #expect(p.requests[1].admission?.owner === receipt.owner)
        #expect(p.requests[1].admission?.source == receipt.source)
        #expect(p.directNativeISO == 0)
    }

    @Test func anExpiredColorHeldZoomReleasesOnlyItsOwnPendingStageWithoutALateWrite() {
        let p = ZoomPeer()
        let gate = Gate()
        var refused = 0
        p.gesture.slider(
            3, admission: .init(owner: p.native, isCurrent: { gate.isCurrent }),
            onStage: { if $0 == .notSent { refused += 1 } })
        #expect(p.requests.count == 1 && p.color.snapshot.pendingFactor == 3)
        gate.revoke()
        p.status.colorMode = .dLog
        p.gesture.confirmIfReady()
        #expect(p.requests.count == 1 && refused == 1)
        #expect(p.color.snapshot.pendingFactor == nil)
        p.gesture.confirmIfReady()
        #expect(refused == 1 && p.requests.count == 1)
    }

    @Test func aDifferentSameKeySuccessorNeverBorrowsTheFirstHeldZoomReceipt() {
        let p = ZoomPeer()
        let first = Gate()
        let second = Gate()
        var retired = 0
        var currentRefused = 0
        p.gesture.slider(
            3, admission: .init(owner: p.native, isCurrent: { first.isCurrent }),
            onStage: { if $0 == .notSent { retired += 1 } })
        p.gesture.slider(
            4, admission: .init(owner: p.native, isCurrent: { second.isCurrent }),
            onStage: { if $0 == .notSent { currentRefused += 1 } })
        first.revoke()
        p.status.colorMode = .dLog
        p.gesture.confirmIfReady()
        #expect(retired == 1 && currentRefused == 0)
        #expect(p.requests.count == 2)
        #expect(p.requests[1].frame == Commands.setZoomLens(CamFov.pinchLens(for: 4)))
        #expect(p.requests[1].admission?.isCurrent == true)
        second.revoke()
        #expect(p.requests[1].admission?.isCurrent == false)
    }

    @Test func expiryDuringColorDispatchCannotStartItsUnsentNativeISOFollowUp() {
        let p = ZoomPeer()
        let gate = Gate()
        p.onSend = { gate.revoke() }
        p.gesture.chip(3, admission: .init(owner: p.native, isCurrent: { gate.isCurrent }))
        #expect(p.requests.count == 1 && p.isoReceipts.isEmpty && p.directNativeISO == 0)
    }

    @Test func originalColorRestoreUsesTheCurrentWideOperationReceipt() {
        let p = ZoomPeer()
        let first = DJICommandAdmission(owner: p.native, isCurrent: { true })
        p.gesture.slider(3, admission: first)
        p.status.colorMode = .dLog
        p.gesture.confirmIfReady()
        let gate = Gate()
        let wide = DJICommandAdmission(owner: p.native, isCurrent: { gate.isCurrent })
        p.gesture.chip(1, admission: wide)
        let restores = p.requests.filter { $0.frame == Commands.setColorMode(.dLog2, model: nil) }
        #expect(restores.count == 1 && restores[0].admission?.isCurrent == true)
        gate.revoke()
        #expect(restores[0].admission?.isCurrent == false && first.isCurrent)
    }

    @MainActor private final class FocusPeer {
        let endpoint = NSObject()
        let native = DJICommandOwner()
        var direct: [Duml.Frame] = []
        var frames: [Duml.Frame] = []
        var prepared: [UInt16] = []
        var receipts: [DJICommandAdmission] = []
        var timeouts: [Duration] = []
        var enteredCompletions = 0
        var afterPrepare: (() -> Void)?
        var afterRequest: (() -> Void)?
        lazy var focus = DjiAppleTapFocus(
            binding: { [unowned self] in
                .init(endpoint: ObjectIdentifier(endpoint), controlGeneration: 1)
            },
            sendPrepare: { [unowned self] in
                direct.append($0)
                return 0
            },
            request: { [unowned self] frame, _, _ in
                direct.append(frame)
                return true
            },
            prepared: { [unowned self] _, sequence in prepared.append(sequence) },
            sendAdmittedPrepare: { [unowned self] frame, admission in
                guard admission.admits(native) else { return .skipped }
                frames.append(frame)
                receipts.append(admission)
                afterPrepare?()
                return .queued(0)
            },
            admittedRequest: { [unowned self] frame, _, timeout, admission in
                guard admission.admits(native) else { return false }
                frames.append(frame)
                receipts.append(admission)
                timeouts.append(timeout)
                afterRequest?()
                enteredCompletions += 1
                return true
            })
    }

    @MainActor private final class ZoomPeer {
        let endpoint = NSObject()
        let native = DJICommandOwner()
        var status = CameraStatus()
        var requests: [DjiAppleControlExchange.SetRequest] = []
        var isoReceipts: [DJICommandAdmission] = []
        var directNativeISO = 0
        var onSend: (() -> Void)?
        lazy var color: DjiAppleZoomColor = DjiAppleZoomColor(
            binding: { [unowned self] in
                .init(endpoint: ObjectIdentifier(endpoint), controlGeneration: 1)
            },
            facts: { [unowned self] in
                .init(
                    status: status, model: nil,
                    supportsZoom: true, previewing: false, locked: false)
            },
            send: { [unowned self] request, _ in
                requests.append(request)
                onSend?()
            },
            now: { Date(timeIntervalSinceReferenceDate: 0) },
            event: { [unowned self] event in
                if case .flushed(let factor) = event { _ = gesture.flushed(factor) }
                if case .nativeISO = event { directNativeISO += 1 }
            },
            admittedNativeISO: { [unowned self] _, _, receipt in isoReceipts.append(receipt) })
        lazy var gesture: DjiAppleZoomGesture = DjiAppleZoomGesture(
            binding: { [unowned self] in
                .init(endpoint: ObjectIdentifier(endpoint), controlGeneration: 1)
            },
            facts: { [unowned self] in
                .init(
                    status: status, stops: CamFov.jumps,
                    supportsZoom: true, locked: false)
            }, color: color, now: { 0 }, sendStop: { _, done in done(true) })
        init() {
            status.colorMode = .dLog2
            status.zoomFactorRaw = CamFov.rawAt1x
        }
    }
}
