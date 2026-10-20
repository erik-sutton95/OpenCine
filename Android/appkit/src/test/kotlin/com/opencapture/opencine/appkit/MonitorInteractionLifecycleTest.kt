package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID
import kotlin.test.*

class MonitorInteractionLifecycleTest {
    @Test fun transientPanelCollapsesPaletteWithoutDismissingItsOwnPanel() {
        val owner = MonitorInteractionLifecycle()
        owner.update(MonitorInteractionContext())
        val panel = owner.update(MonitorInteractionContext(transientPanelPresented = true))
        assertTrue(panel.collapseAssists)
        assertFalse(panel.dismissTransients || panel.retireReadout)
        assertNull(panel.inputAdmission)
    }
    @Test fun lockRetiresInputOnceAndCoverReturnStaysBlockedUntilUnlocked() {
        val owner = MonitorInteractionLifecycle()
        assertEquals(MonitorInputAdmission.Resumed, owner.update(MonitorInteractionContext()).inputAdmission)
        val lock = owner.update(MonitorInteractionContext(locked = true))
        assertTrue(lock.dismissTransients && lock.retireReadout && lock.collapseAssists)
        assertEquals(MonitorInputAdmission.Blocked(MonitorInputBlock.LOCK), lock.inputAdmission)
        assertNull(owner.update(MonitorInteractionContext(locked = true)).inputAdmission)
        assertNull(owner.update(MonitorInteractionContext(locked = true, covered = true)).inputAdmission)
        assertNull(owner.update(MonitorInteractionContext(locked = true)).inputAdmission)
        assertEquals(MonitorInputAdmission.Resumed, owner.update(MonitorInteractionContext()).inputAdmission)
    }
    @Test fun coverBorrowsAndReturnResumesWithoutInferringARecordOperation() {
        val owner = MonitorInteractionLifecycle()
        owner.update(MonitorInteractionContext())
        val cover = owner.update(MonitorInteractionContext(covered = true))
        // The cover keeps an open picker for the return; only held input retires.
        assertFalse(cover.dismissTransients)
        assertTrue(cover.retireReadout)
        assertFalse(cover.collapseAssists)
        assertEquals(MonitorInputAdmission.Blocked(MonitorInputBlock.COVER), cover.inputAdmission)
        val back = owner.update(MonitorInteractionContext())
        assertEquals(MonitorInputAdmission.Resumed, back.inputAdmission)
        assertFalse(back.dismissTransients)
        assertNull(owner.update(MonitorInteractionContext()).inputAdmission)
    }
    @Test fun rotationRetiresReadoutWhileCleanAndEditingRetireAllTransients() {
        val owner = MonitorInteractionLifecycle()
        owner.update(MonitorInteractionContext())
        val rotation = owner.update(MonitorInteractionContext(orientationRevision = 1))
        assertTrue(rotation.retireReadout); assertFalse(rotation.dismissTransients)
        val clean = owner.update(MonitorInteractionContext(clean = true, orientationRevision = 1))
        assertTrue(clean.dismissTransients); assertNull(clean.inputAdmission)
        val edit = owner.update(MonitorInteractionContext(editing = true, clean = true, orientationRevision = 1))
        assertTrue(edit.dismissTransients)
        assertEquals(MonitorInputAdmission.Blocked(MonitorInputBlock.EDIT), edit.inputAdmission)
    }
    @Test fun replacementAndReentryCannotReuseThePreviousPresentation() {
        val owner = MonitorInteractionLifecycle()
        val a = CameraSessionID(); val b = CameraSessionID()
        owner.update(MonitorInteractionContext(camera = a))
        val replaced = owner.update(MonitorInteractionContext(camera = b))
        assertTrue(replaced.dismissTransients && replaced.retireReadout)
        assertEquals(MonitorInputAdmission.Resumed, replaced.inputAdmission)
        // Only a new camera resets per-camera readout choices (the storage form).
        assertTrue(replaced.cameraReplaced)
        assertFalse(owner.update(MonitorInteractionContext(locked = true, camera = b)).cameraReplaced)
        owner.update(MonitorInteractionContext(camera = b))
        assertEquals(MonitorInputAdmission.Blocked(MonitorInputBlock.DISAPPEARED), owner.close().inputAdmission)
        assertNull(owner.context)
        val reentry = owner.update(MonitorInteractionContext(covered = true, camera = b))
        assertTrue(reentry.dismissTransients)
        assertEquals(MonitorInputAdmission.Blocked(MonitorInputBlock.COVER), reentry.inputAdmission)
        // A lock under a cover still dismisses.
        assertTrue(owner.update(MonitorInteractionContext(locked = true, covered = true, camera = b)).dismissTransients)
    }
}
