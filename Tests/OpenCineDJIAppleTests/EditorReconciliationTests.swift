import Foundation
import OpenCineDJI
import OpenCineDJIApple
import Testing

/// SIMULATED pending editor values and actual sparse status; manual time, no native IO.
@Suite @MainActor
struct DJIAppleEditorReconciliationTests {
    @MainActor private final class Peer {
        var time: TimeInterval = 0
        var binding = DjiAppleSettingsBinding()
        var committed = CameraStatus()
        var changed: ((WhiteBalance?, WhiteBalance?) -> Void)?
        lazy var owner: DjiAppleEditorReconciliation = DjiAppleEditorReconciliation(
            binding: { [unowned self] in binding },
            now: { [unowned self] in Date(timeIntervalSinceReferenceDate: time) },
            whiteBalanceChanged: { [unowned self] in changed?($0, $1) })
        func project(
            _ incoming: CameraStatus, reported: CameraStatus = .init(),
            origin: DjiAppleEditorReconciliation.Origin = .subscription
        ) -> DjiAppleEditorReconciliation.Projection {
            owner.project(
                incoming: incoming, reported: reported, committed: committed, origin: origin)
        }
    }

    @Test func optimisticWhiteBalanceCannotConfirmWithoutThisFrameReport() {
        let p = Peer()
        let requested = WhiteBalance.custom(kelvin: 5600, tint: 0)
        let token = p.owner.holdWhiteBalance(requested)
        var accumulated = p.committed
        accumulated.whiteBalance = requested
        let first = p.project(accumulated)
        #expect(first.status.whiteBalance == requested)
        #expect(p.owner.requestedWhiteBalance == requested && p.owner.isPending(token))
        var sparse = CameraStatus()
        sparse.whiteBalance = requested
        _ = p.project(accumulated, reported: sparse)
        #expect(p.owner.requestedWhiteBalance == nil && !p.owner.isPending(token))
    }

    @Test func supersededChoiceFailureCannotClearSuccessorOrChangeCommittedCamera() {
        let p = Peer()
        let previous = p.owner.holdIsoLimit(.max800)
        let current = p.owner.holdIsoLimit(.max1600)
        #expect(previous.id != current.id)
        #expect(!p.owner.reject(previous) && p.owner.isPending(current))
        #expect(p.committed.isoLimit == nil)
        #expect(p.owner.reject(current) && !p.owner.isPending(current))
    }

    @Test func unrelatedSparseReportDoesNotInvalidatePendingRequestIdentity() {
        let p = Peer()
        let current = p.owner.holdFocusMode(.continuous)
        var unrelated = CameraStatus()
        unrelated.colorMode = .normal
        let result = p.project(p.committed, reported: unrelated)
        #expect(result.status.focusMode == .continuous)
        #expect(p.owner.isPending(current))
    }

    @Test func choiceProjectionExpiresAtExactlyTwoSeconds() {
        let p = Peer()
        let current = p.owner.holdShootingMode(1)
        p.time = 1.999
        #expect(p.project(p.committed).status.shootingMode == 1)
        p.time = 2
        #expect(p.project(p.committed).status.shootingMode == p.committed.shootingMode)
        #expect(!p.owner.isPending(current))
    }

    @Test func audioRetainsExactNullableIncomingClauseAndIndependentConfirmation() {
        let p = Peer()
        p.committed.audioChannel = .stereo
        p.committed.vocalBoost = .off
        p.owner.pinAudio(channel: .mono, vocal: .on)
        let absent = p.project(CameraStatus())
        #expect(absent.status.audioChannel == nil && absent.status.vocalBoost == nil)
        var stale = p.committed
        stale.audioChannel = .mono
        stale.vocalBoost = .on
        let held = p.project(stale)
        #expect(held.status.audioChannel == .stereo && held.status.vocalBoost == .off)
        var sparse = CameraStatus()
        sparse.audioChannel = .mono
        let partial = p.project(stale, reported: sparse)
        #expect(partial.status.audioChannel == .mono && partial.status.vocalBoost == .off)
        p.time = 2
        let expired = p.project(stale)
        #expect(expired.status.audioChannel == .mono && expired.status.vocalBoost == .on)
    }

    @Test func isoIndexCanConfirmByActualCorrespondingISOValue() {
        let p = Peer()
        p.committed.iso = 100
        p.committed.isoIndex = .iso100
        p.owner.pinExpo(iso: 800, isoIndex: .iso800)
        var incoming = p.committed
        incoming.iso = 800
        incoming.isoIndex = .iso800
        let stale = p.project(incoming)
        #expect(stale.status.iso == 100 && stale.status.isoIndex == .iso100)
        var sparse = CameraStatus()
        sparse.iso = 800
        let confirmed = p.project(incoming, reported: sparse)
        #expect(confirmed.status.iso == 800 && confirmed.status.isoIndex == .iso800)
    }

    @Test func earlyExposureCannotConfirmFormatOrConsumeOperatorAngle() {
        let p = Peer()
        p.committed.expoMode = .manual
        p.committed.videoFormat = VideoFormat(resolution: .p4K, frameRate: .fps24)
        p.committed.fps = 24
        let requested = VideoFormat(resolution: .p4K, frameRate: .fps60)
        p.owner.holdFormat(requested, shutterAngle: 180)
        var exposure = CameraStatus()
        exposure.shutterDenom = 120
        let held = p.project(p.committed, reported: exposure)
        #expect(held.status.fps == 60 && held.status.shutterDenom == 120)
        #expect(p.owner.hasFormat && p.owner.requestedFormatAngle == 180)
        #expect(held.rematchAngle == nil)
    }

    @Test func onlyActualFormatReportReleasesLatestAngleOnce() {
        let p = Peer()
        p.committed.expoMode = .manual
        let requested = VideoFormat(resolution: .p4K, frameRate: .fps60)
        p.owner.holdFormat(requested, shutterAngle: 180)
        p.owner.holdFormatAngle(90)
        var actual = p.committed
        actual.videoFormat = requested
        actual.videoResolution = requested.resolution
        actual.fps = 60
        let confirmed = p.project(actual, reported: actual)
        #expect(confirmed.rematchAngle == 90 && !p.owner.hasFormat)
        #expect(p.project(actual, reported: actual).rematchAngle == nil)
    }

    @Test func eightSecondFormatAngleExpiryRetainsOriginalNoticeFact() {
        let p = Peer()
        p.committed.expoMode = .manual
        p.owner.holdFormat(VideoFormat(resolution: .p4K, frameRate: .fps60), shutterAngle: 180)
        p.time = 7.999
        #expect(!p.project(p.committed).formatExpired && p.owner.hasFormat)
        p.time = 8
        let expired = p.project(p.committed)
        #expect(expired.formatExpired && !p.owner.hasFormat && expired.rematchAngle == nil)
    }

    @Test func subscriptionModeChangeRetiresFormatWhileAckKeepsIndependentDomains() {
        let p = Peer()
        p.committed.shootingMode = 1
        p.owner.holdFormat(VideoFormat(resolution: .p4K, frameRate: .fps60), shutterAngle: nil)
        var next = p.committed
        next.shootingMode = 2
        _ = p.project(next, reported: next, origin: .acknowledgment)
        #expect(p.owner.hasFormat)
        let subscriber = p.project(next, reported: next)
        #expect(subscriber.captureModeChanged && !p.owner.hasFormat)
        #expect(p.owner.captureGeneration == 1)
    }

    @Test func committedWhiteBalanceCallbackReplacementRejectsOutgoingProjection() {
        let p = Peer()
        let first = WhiteBalance.custom(kelvin: 5600, tint: 0)
        let successor = WhiteBalance.custom(kelvin: 6500, tint: 0)
        _ = p.owner.holdWhiteBalance(first)
        var acted = false
        p.changed = { previous, next in
            guard !acted else { return }
            acted = true
            #expect(previous == first && next == nil)
            #expect(p.owner.requestedWhiteBalance == nil)
            _ = p.owner.holdWhiteBalance(successor)
        }
        var actual = p.committed
        actual.whiteBalance = first
        let outgoing = p.project(actual, reported: actual)
        #expect(acted && !p.owner.admits(outgoing.authority))
        #expect(p.owner.requestedWhiteBalance == successor)
    }

    @Test func retirementInvalidatesCapturedProjectionAndRequestsWithoutCameraFacts() {
        let p = Peer()
        let requested = p.owner.holdFocusMode(.continuous)
        let authority = p.project(p.committed).authority
        p.owner.pinAudio(channel: .mono)
        p.owner.pinExpo(shutter: 120)
        p.owner.holdColor(.dLog)
        p.owner.retire()
        #expect(!p.owner.admits(authority) && !p.owner.isPending(requested))
        #expect(!p.owner.needsSparseReport && p.committed == CameraStatus())
    }
    @Test func requestingWhiteBalanceCallbackCanReplaceBeforeCallerAdmission() {
        let p = Peer()
        let first = WhiteBalance.custom(kelvin: 5600, tint: 0)
        let successor = WhiteBalance.custom(kelvin: 6500, tint: 0)
        var acted = false
        p.changed = { _, next in
            guard !acted else { return }
            acted = true
            #expect(next == first && p.owner.requestedWhiteBalance == first)
            _ = p.owner.holdWhiteBalance(successor)
        }
        let outgoing = p.owner.holdWhiteBalance(first)
        #expect(acted && !p.owner.isPending(outgoing))
        #expect(p.owner.requestedWhiteBalance == successor && p.committed.whiteBalance == nil)
    }

    @Test func mixedExposureConfirmationRetainsOnlyTheStillUnconfirmedField() {
        let p = Peer()
        p.committed.iso = 100
        p.committed.isoIndex = .iso100
        p.committed.shutterDenom = 48
        p.owner.pinExpo(iso: 800, isoIndex: .iso800, shutter: 120)
        var incoming = p.committed
        incoming.iso = 800
        incoming.isoIndex = .iso800
        incoming.shutterDenom = 120
        var sparse = CameraStatus()
        sparse.iso = 800
        let partial = p.project(incoming, reported: sparse)
        #expect(partial.status.iso == 800 && partial.status.isoIndex == .iso800)
        #expect(partial.status.shutterDenom == 48)
        p.time = 2
        #expect(p.project(incoming).status.shutterDenom == 120)
    }

    @Test func actualAutoReportRetiresDeferredAngleBeforeDelayedFormatCanRematch() {
        let p = Peer()
        p.committed.expoMode = .manual
        let requested = VideoFormat(resolution: .p4K, frameRate: .fps60)
        p.owner.holdFormat(requested, shutterAngle: 180)
        var automatic = p.committed
        automatic.expoMode = .auto
        _ = p.project(automatic, reported: automatic)
        #expect(p.owner.hasFormat && p.owner.requestedFormatAngle == nil)
        automatic.videoFormat = requested
        automatic.videoResolution = requested.resolution
        automatic.fps = 60
        let late = p.project(automatic, reported: automatic)
        #expect(late.rematchAngle == nil && !p.owner.hasFormat)
    }

    @Test func ordinaryColorAndFormatExpiryUseExactlyTwoSeconds() {
        let p = Peer()
        p.committed.colorMode = .normal
        let format = VideoFormat(resolution: .p4K, frameRate: .fps60)
        p.owner.holdColor(.dLog)
        p.owner.holdFormat(format, shutterAngle: nil)
        var incoming = p.committed
        incoming.colorMode = .dLog
        p.time = 1.999
        let held = p.project(incoming)
        #expect(held.status.colorMode == .normal && held.status.fps == 60)
        p.time = 2
        let expired = p.project(incoming)
        #expect(expired.status.colorMode == .dLog && !p.owner.hasFormat)
        #expect(!expired.formatExpired && expired.rematchAngle == nil)
    }

    @Test func expiredWhiteBalanceCallbackRetiresProjectionButNotValidSameSourceReceipt() {
        let p = Peer()
        _ = p.owner.holdWhiteBalance(.custom(kelvin: 5600, tint: 0))
        p.owner.holdFormat(VideoFormat(resolution: .p4K, frameRate: .fps60), shutterAngle: 180)
        let receiptSource = p.owner.authority
        var successor: DjiAppleEditorReconciliation.Request?
        p.changed = { _, next in
            #expect(next == nil)
            successor = p.owner.holdIsoLimit(.max800)
        }
        p.time = 2.15
        let result = p.project(p.committed, origin: .acknowledgment)
        #expect(!p.owner.admits(result.authority))
        #expect(p.owner.admitsSource(receiptSource))
        #expect(CameraReply.parse([0]).isSuccess)
        #expect(p.owner.hasFormat && p.owner.requestedFormatAngle == 180)
        #expect(successor.map { p.owner.isPending($0) } == true)
    }

    @Test func connectionReplacementDuringCallbackRejectsReceiptSourceAndOldRequest() {
        let p = Peer()
        let request = p.owner.holdWhiteBalance(.custom(kelvin: 5600, tint: 0))
        let receiptSource = p.owner.authority
        p.changed = { _, next in
            #expect(next == nil)
            p.binding.controlGeneration += 1
        }
        p.time = 2.15
        let result = p.project(p.committed, origin: .acknowledgment)
        #expect(!p.owner.admits(result.authority) && !p.owner.admitsSource(receiptSource))
        #expect(!p.owner.isPending(request))
    }

    @Test func localRetirementInCallbackRejectsOtherwiseSuccessfulCapturedReceipt() {
        let p = Peer()
        _ = p.owner.holdWhiteBalance(.custom(kelvin: 5600, tint: 0))
        let receiptSource = p.owner.authority
        p.changed = { _, next in
            #expect(next == nil)
            p.owner.retire()
        }
        p.time = 2.15
        _ = p.project(p.committed, origin: .acknowledgment)
        #expect(CameraReply.parse([0]).isSuccess)
        #expect(!p.owner.admitsSource(receiptSource))
        #expect(!CameraReply.parse([1]).isSuccess)
    }

}
