package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.CameraSessionID

/** Facts that admit operator input. A cover borrows the camera without closing it. */
public data class MonitorInteractionContext(
    public val locked: Boolean = false,
    public val covered: Boolean = false,
    public val editing: Boolean = false,
    public val clean: Boolean = false,
    public val toolbarMounted: Boolean = true,
    public val transientPanelPresented: Boolean = false,
    public val camera: CameraSessionID? = null,
    public val orientationRevision: Int = 0,
) {
    public val inputBlock: MonitorInputBlock? get() = when {
        locked -> MonitorInputBlock.LOCK
        covered -> MonitorInputBlock.COVER
        editing -> MonitorInputBlock.EDIT
        else -> null
    }
}

public enum class MonitorInputBlock { LOCK, COVER, EDIT, DISAPPEARED }
public sealed interface MonitorInputAdmission {
    public data class Blocked(public val reason: MonitorInputBlock) : MonitorInputAdmission
    public data object Resumed : MonitorInputAdmission
}
public data class MonitorInteractionTransition(
    public val dismissTransients: Boolean,
    public val retireReadout: Boolean,
    public val collapseAssists: Boolean,
    public val inputAdmission: MonitorInputAdmission?,
    /** A different camera replaced the previous one: per-camera readout choices start over. */
    public val cameraReplaced: Boolean = false,
)

/** Shared lock, cover, edit, clean, rotation and replacement lifecycle. No camera commands. */
public class MonitorInteractionLifecycle {
    public var context: MonitorInteractionContext? = null
        private set

    public fun update(next: MonitorInteractionContext): MonitorInteractionTransition {
        val previous = context
        context = next
        val replaced = previous != null && previous.camera != next.camera
        // A cover borrows the monitor: an open picker stays, hidden and inert, and returns
        // with its state. Lock, chrome edit, clean view and a new camera still dismiss it.
        val enteredBlock = next.inputBlock != null && previous?.inputBlock != next.inputBlock &&
            (next.inputBlock != MonitorInputBlock.COVER || previous == null)
        val enteredCover = next.covered && previous?.covered != true
        val enteredClean = next.clean && previous?.clean != true
        val enteredEdit = next.editing && previous?.editing != true
        val dismiss = replaced || enteredBlock || enteredClean || enteredEdit
        val rotated = previous != null && previous.orientationRevision != next.orientationRevision
        val admission = if (previous == null || previous.inputBlock != next.inputBlock || replaced) {
            next.inputBlock?.let { MonitorInputAdmission.Blocked(it) } ?: MonitorInputAdmission.Resumed
        } else null
        // Held input (a quick drag in flight) never survives a turn or a cover.
        return MonitorInteractionTransition(dismiss, dismiss || rotated || enteredCover,
            dismiss || !next.toolbarMounted || next.transientPanelPresented, admission, replaced)
    }

    public fun close(): MonitorInteractionTransition {
        context = null
        return MonitorInteractionTransition(true, true, true,
            MonitorInputAdmission.Blocked(MonitorInputBlock.DISAPPEARED))
    }
}
