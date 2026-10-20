import OpenCineAppKit
import OpenCineCore
import Testing

struct MonitorInteractionLifecycleTests {
    @Test func presentingATransientPanelCollapsesThePaletteWithoutDismissingItsOwnPanel() {
        var owner = MonitorInteractionLifecycle()
        _ = owner.update(.init())
        let panel = owner.update(.init(transientPanelPresented: true))
        #expect(panel.collapseAssists && !panel.dismissTransients && !panel.retireReadout)
        #expect(panel.inputAdmission == nil)
    }
    @Test func lockRetiresTransientInputOnceAndCoverReturnStaysBlockedUntilUnlocked() {
        var owner = MonitorInteractionLifecycle()
        #expect(owner.update(.init()).inputAdmission == .resumed)
        let lock = owner.update(.init(locked: true))
        #expect(lock.dismissTransients && lock.retireReadout && lock.collapseAssists)
        #expect(lock.inputAdmission == .blocked(.lock))
        #expect(owner.update(.init(locked: true)).inputAdmission == nil)
        #expect(owner.update(.init(locked: true, covered: true)).inputAdmission == nil)
        #expect(owner.update(.init(locked: true, covered: false)).inputAdmission == nil)
        #expect(owner.update(.init()).inputAdmission == .resumed)
    }
    @Test func coverBorrowsAndReturnResumesWithoutInferringARecordOperation() {
        var owner = MonitorInteractionLifecycle()
        _ = owner.update(.init())
        let cover = owner.update(.init(covered: true))
        // The cover keeps an open picker for the return; only held input retires.
        #expect(cover.inputAdmission == .blocked(.cover) && !cover.dismissTransients && cover.retireReadout)
        #expect(!cover.collapseAssists)
        let back = owner.update(.init())
        #expect(back.inputAdmission == .resumed && !back.dismissTransients)
        #expect(owner.update(.init()).inputAdmission == nil)
    }
    @Test func rotationRetiresReadoutWhileCleanAndEditingRetireAllTransientPresentation() {
        var owner = MonitorInteractionLifecycle()
        _ = owner.update(.init())
        let rotation = owner.update(.init(orientationRevision: 1))
        #expect(rotation.retireReadout && !rotation.dismissTransients)
        let clean = owner.update(.init(clean: true, orientationRevision: 1))
        #expect(clean.dismissTransients && clean.inputAdmission == nil)
        let edit = owner.update(.init(editing: true, clean: true, orientationRevision: 1))
        #expect(edit.dismissTransients && edit.inputAdmission == .blocked(.edit))
    }
    @Test func replacementAndReentryCannotReuseThePreviousPresentation() {
        var owner = MonitorInteractionLifecycle()
        let a = CameraSessionID(), b = CameraSessionID()
        _ = owner.update(.init(camera: a))
        let replaced = owner.update(.init(camera: b))
        #expect(replaced.dismissTransients && replaced.retireReadout)
        #expect(replaced.inputAdmission == .resumed)
        // Only a new camera resets per-camera readout choices (the storage form).
        #expect(replaced.cameraReplaced)
        #expect(!owner.update(.init(locked: true, camera: b)).cameraReplaced)
        _ = owner.update(.init(camera: b))
        #expect(owner.close().inputAdmission == .blocked(.disappeared))
        #expect(owner.context == nil)
        let reentry = owner.update(.init(covered: true, camera: b))
        #expect(reentry.dismissTransients && reentry.inputAdmission == .blocked(.cover))
        // A lock under a cover still dismisses.
        #expect(owner.update(.init(locked: true, covered: true, camera: b)).dismissTransients)
    }
}
