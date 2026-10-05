package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.luna.LunaSubjectTracking.Box
import com.opencapture.opencine.insta360.luna.LunaSubjectTracking.Snapshot
import com.opencapture.opencine.insta360.shell.CameraNotice
import com.opencapture.opencine.insta360.shell.CameraTrackFrame
import com.opencapture.opencine.insta360.shell.CameraTrackState
import kotlin.test.*
import kotlinx.coroutines.runBlocking
import org.junit.Test

/** Swift `LunaSubjectTrackingTests`, over the backend's controls. */
class LunaSubjectTrackingTest {
    private val controls = RecordingControls()
    private val published = mutableListOf<Snapshot>()
    private val tracking = LunaSubjectTracking({ controls }, { published += it })
    private val search = Box(0.35, 0.3, 0.2, 0.2)

    private fun frame(state: CameraTrackState, x: Double) = CameraTrackFrame(state, x, 0.3, 0.15, 0.27)

    /** Moved from the Insta app's `LunaShellMappingTest.deepTrackStreamStatesDriveTheBoxes`. */
    @Test fun streamStatesDriveTheBoxes() = runBlocking {
        assertFalse(tracking.ingest(frame(CameraTrackState.IDLE, 0.4)), "idle before any lock is ignored")
        assertFalse(tracking.ingest(frame(CameraTrackState.LOST, 0.4)), "lost before any lock is ignored")
        assertTrue(published.isEmpty())
        tracking.start(search)
        assertEquals(Snapshot(searchBox = search), tracking.snapshot, "the requested box searches until the lock")
        assertTrue(tracking.snapshot.active)
        assertTrue(tracking.ingest(frame(CameraTrackState.TRACKING, 0.4)))
        assertEquals(Snapshot(subjectBox = Box(0.4, 0.3, 0.15, 0.27), tracking = true), tracking.snapshot)
        assertTrue(tracking.ingest(frame(CameraTrackState.LOST, 0.42)))
        assertEquals(Snapshot(searchBox = Box(0.42, 0.3, 0.15, 0.27)), tracking.snapshot)
        assertTrue(tracking.snapshot.active, "lost keeps tracking active so cancel stays available")
        assertTrue(tracking.ingest(frame(CameraTrackState.TRACKING, 0.3)))
        assertTrue(tracking.snapshot.tracking)
        assertTrue(tracking.ingest(frame(CameraTrackState.IDLE, 0.3)))
        assertFalse(tracking.snapshot.active, "idle after a lock ends tracking")
        assertFalse(tracking.ingest(frame(CameraTrackState.IDLE, 0.3)), "and the lock is forgotten")
        assertEquals(tracking.snapshot, published.last())
    }

    /** Moved from the Insta app's `LunaShellMappingTest.deepTrackNoticeLocksOrEndsTracking`. */
    @Test fun noticesLockOrEndTracking() = runBlocking {
        assertFalse(tracking.ingest(CameraNotice.Tracking(false)), "an end notice without tracking changes nothing")
        tracking.start(search)
        assertTrue(tracking.ingest(CameraNotice.Tracking(true)))
        assertEquals(Snapshot(subjectBox = search.subject(), tracking = true), tracking.snapshot, "a lock notice promotes the search box")
        assertTrue(tracking.ingest(CameraNotice.Tracking(false)))
        assertFalse(tracking.snapshot.active, "8315 cancelled on the camera clears tracking")
        tracking.start(search)
        assertTrue(tracking.ingest(CameraNotice.Tracking(false)))
        assertFalse(tracking.snapshot.active, "an end before the lock drops the search box")
        // A lock notice without a search keeps the subject the stream reported.
        assertTrue(tracking.ingest(frame(CameraTrackState.TRACKING, 0.5)))
        assertTrue(tracking.ingest(CameraNotice.Tracking(true)))
        assertEquals(Box(0.5, 0.3, 0.15, 0.27), tracking.snapshot.subjectBox)
    }

    @Test fun subjectIsFortyFivePercentAtLeastFivePercentCentred() {
        assertEquals(Box(0.405, 0.355, 0.09, 0.09), search.subject().let { Box(round(it.x), round(it.y), round(it.width), round(it.height)) })
        assertEquals(Box(0.5, 0.5, 0.05, 0.05), Box(0.5, 0.5, 0.05, 0.05).subject(), "never larger than the box")
        assertEquals(0.05, Box(0.1, 0.1, 0.1, 0.1).subject().width, 1e-12)
    }

    private fun round(v: Double) = Math.round(v * 1e9) / 1e9

    @Test fun startKeepsTheBoxInsideTheFrameAndARefusedStartClears() = runBlocking {
        assertTrue(tracking.start(Box(0.8, -0.1, 0.4, 0.3)))
        assertEquals(listOf(listOf<Any?>(0.8, 0.0, minOf(0.4, 1 - 0.8), 0.3)), controls.calls("startTracking"))
        controls.accepts = false
        assertFalse(tracking.start(search))
        assertEquals(Snapshot(), tracking.snapshot)
        assertEquals(listOf(Snapshot(searchBox = search), Snapshot()), published.takeLast(2), "the search shows, then clears")
    }

    @Test fun cancelSendsOnlyWhileActive() = runBlocking {
        assertFalse(tracking.cancel())
        assertTrue(controls.calls("stopTracking").isEmpty())
        assertTrue(published.isEmpty(), "an inactive cancel publishes nothing")
        tracking.start(search)
        assertTrue(tracking.cancel())
        assertEquals(Snapshot(), tracking.snapshot)
        assertEquals(1, controls.calls("stopTracking").size)
    }

    @Test fun focusSendsThePointAndReportsTheAnswer() = runBlocking {
        assertTrue(tracking.focus(0.3, 0.6))
        assertEquals(listOf(listOf<Any?>(0.3, 0.6)), controls.calls("tapFocus"))
        controls.accepts = false
        assertFalse(tracking.focus(0.5, 0.5))
        assertFalse(LunaSubjectTracking({ null }).focus(0.5, 0.5), "no controls, no focus")
    }
}
