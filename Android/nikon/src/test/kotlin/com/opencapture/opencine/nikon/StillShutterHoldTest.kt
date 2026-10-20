package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Twin of Swift `StillShutterHoldTests` and `NikonBodyCaptureFilterTests`. */
class StillShutterHoldTest {
    @Test
    fun `a quick tap in continuous drive keeps its one frame`() {
        val hold = StillShutterHold(continuousDrive = true)
        assertEquals(StillShutterHold.Release.SINGLE_FRAME, hold.nextRelease)
        assertEquals(StillShutterHold.FingerUp.LET_RELEASE_FINISH, hold.fingerUp())
        assertFalse(hold.releaseCompleted())
        assertEquals(0, hold.burstRuns)
    }

    @Test
    fun `a hold in continuous drive chains burst runs that finger-up ends`() {
        val hold = StillShutterHold(continuousDrive = true)
        assertTrue(hold.releaseCompleted())
        assertEquals(StillShutterHold.Release.BURST_RUN, hold.nextRelease)
        assertTrue(hold.releaseCompleted())
        assertEquals(StillShutterHold.FingerUp.END_BURST, hold.fingerUp())
        assertFalse(hold.releaseCompleted())
        assertEquals(2, hold.burstRuns)
    }

    @Test
    fun `single drive never chains or ends`() {
        val hold = StillShutterHold(continuousDrive = false)
        assertFalse(hold.releaseCompleted())
        assertEquals(StillShutterHold.FingerUp.LET_RELEASE_FINISH, hold.fingerUp())
    }

    @Test
    fun `a swallowed finger-up stops at the cap`() {
        val hold = StillShutterHold(continuousDrive = true)
        var runs = 0
        while (hold.releaseCompleted()) runs += 1
        assertEquals(StillShutterHold.MAXIMUM_BURST_RUNS, runs)
        assertEquals(StillShutterHold.FingerUp.END_BURST, hold.fingerUp())
        assertEquals(StillShutterHold.FingerUp.LET_RELEASE_FINISH, hold.fingerUp())
    }

    @Test
    fun `the late half of an app raw plus jpeg pair is not a body shot`() {
        val filter = NikonBodyCaptureFilter()
        assertEquals(NikonBodyCaptureSync.IGNORE, filter.action(0, true, true, true))
        filter.appReleaseCompleted(100)
        assertEquals(NikonBodyCaptureSync.IGNORE, filter.action(1_400, true, true, false))
    }

    @Test
    fun `late objects of an app burst keep extending the tail`() {
        val filter = NikonBodyCaptureFilter()
        val window = NikonBodyCaptureFilter.APP_RELEASE_TAIL_MILLIS
        filter.appReleaseCompleted(0)
        assertEquals(NikonBodyCaptureSync.IGNORE, filter.action(window - 100, true, true, false))
        assertEquals(
            NikonBodyCaptureSync.IGNORE, filter.action(2 * window - 300, true, true, false))
    }

    @Test
    fun `a body shot after the tail is reviewed`() {
        val filter = NikonBodyCaptureFilter()
        filter.appReleaseCompleted(0)
        assertEquals(
            NikonBodyCaptureSync.REVIEW_AND_SHOTS,
            filter.action(NikonBodyCaptureFilter.APP_RELEASE_TAIL_MILLIS + 1, true, true, false),
        )
    }

    @Test
    fun `a body run syncs once`() {
        val filter = NikonBodyCaptureFilter()
        assertEquals(NikonBodyCaptureSync.REVIEW_AND_SHOTS, filter.action(10_000, true, true, false))
        assertEquals(NikonBodyCaptureSync.IGNORE, filter.action(10_500, true, true, false))
        assertEquals(NikonBodyCaptureSync.IGNORE, filter.action(11_200, true, true, false))
        assertEquals(NikonBodyCaptureSync.REVIEW_AND_SHOTS, filter.action(12_100, true, true, false))
    }

    @Test
    fun `movie mode and review off keep their old actions`() {
        val filter = NikonBodyCaptureFilter()
        assertEquals(NikonBodyCaptureSync.IGNORE, filter.action(0, false, true, false))
        assertEquals(NikonBodyCaptureSync.SHOTS_ONLY, filter.action(0, true, false, false))
    }
}
