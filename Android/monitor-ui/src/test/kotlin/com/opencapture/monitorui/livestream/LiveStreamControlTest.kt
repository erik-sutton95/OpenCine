package com.opencapture.monitorui.livestream

import androidx.compose.ui.text.AnnotatedString
import com.opencapture.monitorui.LiveStreamEligibility
import com.opencapture.monitorui.LiveStreamEnd
import com.opencapture.monitorui.LiveStreamHealth
import com.opencapture.monitorui.LiveStreamKeyState
import com.opencapture.monitorui.LiveStreamPhase
import com.opencapture.monitorui.LiveStreamServiceOption
import com.opencapture.monitorui.LiveStreamState
import com.opencapture.monitorui.LiveStreamStatusState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The Go live control's table in `docs/streaming/ui-contract.md`. */
class LiveStreamControlTest {
    private val services = listOf(
        LiveStreamServiceOption("twitch", "Twitch", "hint", false, false, false),
        LiveStreamServiceOption("custom", "Custom server", "hint", true, true, false),
    )
    private val idle = LiveStreamState(services = services, selectedServiceId = "twitch",
        keyState = LiveStreamKeyState.SAVED, eligibility = LiveStreamEligibility.ALLOWED)

    @Test
    fun idleAllowedOffersGoLive() {
        val look = liveStreamControlLook(idle)
        assertEquals(LiveStreamControlLook("Go live", true, null, "Go live", "Starts streaming to Twitch", false), look)
    }

    @Test
    fun ineligibleRouteDisablesGoLiveWithReason() {
        val look = liveStreamControlLook(idle.copy(eligibility = LiveStreamEligibility.CAMERA_WIFI))
        assertFalse(look.enabled)
        assertEquals("Camera Wi-Fi has no internet", look.caption)
        assertEquals("Go live, unavailable", look.label)
        assertTrue(look.hint!!.startsWith("This phone is on the camera's own Wi-Fi"))
        assertEquals("No camera", liveStreamControlLook(idle.copy(eligibility = LiveStreamEligibility.NO_CAMERA)).caption)
    }

    @Test
    fun runningStatesEndTheStream() {
        assertEquals("Connecting to Twitch", liveStreamControlLook(idle.copy(phase = LiveStreamPhase.Connecting)).label)
        val live = liveStreamControlLook(idle.copy(phase = LiveStreamPhase.Live,
            status = LiveStreamStatusState(LiveStreamPhase.Live, 754, 0, 0, LiveStreamHealth.GOOD)))
        assertEquals("LIVE 12:34", live.title)
        assertEquals("Live for 12 minutes 34 seconds", live.label)
        assertEquals("Ends the stream", live.hint)
        assertTrue(live.live)
        val retry = liveStreamControlLook(idle.copy(phase = LiveStreamPhase.Reconnecting(2)))
        assertEquals("Reconnecting" to "Reconnecting, attempt 2", retry.title to retry.label)
    }

    @Test
    fun controlShowsWithASavedKeyOrWhileRunning() {
        assertTrue(idle.showsControl)
        assertFalse(idle.copy(showOnMonitor = false).showsControl)
        assertFalse(idle.copy(keyState = LiveStreamKeyState.ABSENT).showsControl)
        assertTrue(idle.copy(showOnMonitor = false, phase = LiveStreamPhase.Live).showsControl)
    }

    @Test
    fun plainServerWarnsOnlyWhereAccepted() {
        val custom = idle.copy(selectedServiceId = "custom", server = "RTMP://live.example.com/app")
        assertTrue(custom.plainServer)
        assertFalse(custom.copy(server = "rtmps://live.example.com/app").plainServer)
        assertFalse(idle.copy(server = "rtmp://x/y").plainServer)
    }

    @Test
    fun noticeFollowsTheEnd() {
        assertEquals("The stream ended when the app left the screen.",
            idle.copy(phase = LiveStreamPhase.Ended(LiveStreamEnd.Background)).notice)
        assertEquals(null, idle.notice)
    }

    @Test
    fun keyFieldNeverShowsTheKeyOrItsLength() {
        for (key in listOf("a", "live_123456789012345678901234567890")) {
            val shown = FixedLengthMask.filter(AnnotatedString(key))
            assertEquals("•".repeat(8), shown.text.text)
            assertEquals(8, shown.offsetMapping.originalToTransformed(key.length))
            assertEquals(key.length, shown.offsetMapping.transformedToOriginal(8))
        }
        assertEquals("", FixedLengthMask.filter(AnnotatedString("")).text.text)
    }
}
