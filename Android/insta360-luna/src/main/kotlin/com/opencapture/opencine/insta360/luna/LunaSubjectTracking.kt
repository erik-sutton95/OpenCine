package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.CameraControls
import com.opencapture.opencine.insta360.shell.CameraNotice
import com.opencapture.opencine.insta360.shell.CameraTrackFrame
import com.opencapture.opencine.insta360.shell.CameraTrackState

/**
 * One Luna connection's Deep Track and tap focus (Swift `LunaSubjectTracking`). The camera reports
 * Deep Track on every video frame (media 0x85) and its end on notification 8315; requests go out
 * through the backend's [CameraControls], which builds the wire rectangles. Control admission,
 * notes, the face box and the start policy stay with the app. Use from one thread.
 */
class LunaSubjectTracking(
    private val controls: () -> CameraControls?,
    private val changed: (Snapshot) -> Unit = {},
) {
    /** Top-left box in preview fractions, the Luna wire's own frame. */
    data class Box(val x: Double, val y: Double, val width: Double, val height: Double) {
        /** The box shown when the camera locks a search box: 45% of each side, at least 0.05, centred. */
        fun subject(): Box {
            val w = minOf(maxOf(width * 0.45, 0.05), width)
            val h = minOf(maxOf(height * 0.45, 0.05), height)
            return Box(x + (width - w) / 2, y + (height - h) / 2, w, h)
        }
    }

    /** [searchBox]: the operator's request, or the last box while the camera has lost the subject. */
    data class Snapshot(val searchBox: Box? = null, val subjectBox: Box? = null, val tracking: Boolean = false) {
        /** Tracking stays active while any box is up, so cancel stays available. */
        val active: Boolean get() = tracking || searchBox != null || subjectBox != null
    }

    var snapshot = Snapshot()
        private set
    private var sawLock = false

    /** Shows [box] as the search and asks the camera to track it, kept inside the frame; a start the camera does not apply clears it. */
    suspend fun start(box: Box): Boolean {
        sawLock = false
        publish(Snapshot(searchBox = box))
        val left = box.x.coerceIn(0.0, 1.0)
        val top = box.y.coerceIn(0.0, 1.0)
        val ok = controls()?.startTracking(left, top, minOf(box.width, 1 - left), minOf(box.height, 1 - top)) == true
        if (!ok) clear()
        return ok
    }

    /** Clears, then sends the camera's cancel; nothing at all unless tracking was active. */
    suspend fun cancel(): Boolean {
        if (!snapshot.active) return false
        clear()
        return controls()?.stopTracking() == true
    }

    /** Tap focus at a preview point; the backend centres the official ROI on it. */
    suspend fun focus(x: Double, y: Double): Boolean = controls()?.tapFocus(x, y) == true

    /**
     * Media 0x85: tracking moves the subject box with the camera's box; lost shows the last box as a
     * search box until the camera reacquires or the operator cancels; idle after a lock means the
     * camera ended tracking. Idle and lost frames also arrive before the first lock. True when the
     * boxes changed.
     */
    fun ingest(frame: CameraTrackFrame): Boolean {
        val box = Box(frame.x, frame.y, frame.width, frame.height)
        when (frame.state) {
            CameraTrackState.TRACKING -> {
                sawLock = true
                publish(Snapshot(subjectBox = box, tracking = true))
            }
            CameraTrackState.LOST -> if (sawLock) publish(Snapshot(searchBox = box)) else return false
            CameraTrackState.IDLE -> if (sawLock) clear() else return false
        }
        return true
    }

    /** Notification 8315: a lock promotes the search box; an end clears once a lock was seen or a search is pending. True when the boxes changed. */
    fun ingest(notice: CameraNotice.Tracking): Boolean {
        when {
            notice.active -> {
                sawLock = true
                publish(Snapshot(subjectBox = snapshot.searchBox?.subject() ?: snapshot.subjectBox, tracking = true))
            }
            sawLock || snapshot.searchBox != null -> clear()
            else -> return false
        }
        return true
    }

    fun clear() {
        sawLock = false
        publish(Snapshot())
    }

    private fun publish(next: Snapshot) {
        snapshot = next
        changed(next)
    }
}
