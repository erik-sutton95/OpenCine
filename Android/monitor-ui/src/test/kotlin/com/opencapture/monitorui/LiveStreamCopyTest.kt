package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The examples `docs/streaming/ui-contract.md` pins, word for word. */
class LiveStreamCopyTest {
    @Test
    fun elapsedAndSpokenElapsed() {
        assertEquals("12:34", LiveStreamCopy.elapsed(754))
        assertEquals("1:02:03", LiveStreamCopy.elapsed(3723))
        assertEquals("0:05", LiveStreamCopy.elapsed(5))
        assertEquals("12 minutes 34 seconds", LiveStreamCopy.spokenElapsed(754))
        assertEquals("1 hour 2 minutes 3 seconds", LiveStreamCopy.spokenElapsed(3723))
        assertEquals("1 minute 1 second", LiveStreamCopy.spokenElapsed(61))
        assertEquals("LIVE 12:34", LiveStreamCopy.liveTitle(754))
        assertEquals("Live for 12 minutes 34 seconds", LiveStreamCopy.liveLabel(754))
    }

    @Test
    fun bitrates() {
        assertEquals("3.1 Mbps", LiveStreamCopy.bitrate(3_100_000))
        assertEquals("3 Mbps", LiveStreamCopy.bitrate(3_000_000))
        assertEquals("850 kbps", LiveStreamCopy.bitrate(850_000))
        assertEquals("3.1 megabits per second", LiveStreamCopy.spokenBitrate(3_100_000))
        assertEquals("850 kilobits per second", LiveStreamCopy.spokenBitrate(850_000))
    }

    @Test
    fun qualityLines() {
        assertEquals("720p, 30 fps, 3 Mbps", LiveStreamCopy.quality(LiveStreamQuality(1280, 720, 30.0, 3_000_000)))
        assertEquals(
            "720p vertical, 30 fps, 3 Mbps",
            LiveStreamCopy.quality(LiveStreamQuality(720, 1280, 30.0, 3_000_000)),
        )
        assertEquals(
            "1080p, 29.97 fps, 6 Mbps",
            LiveStreamCopy.quality(LiveStreamQuality(1920, 1080, 30_000.0 / 1001, 6_000_000)),
        )
        assertEquals("Set from the camera when you go live.", LiveStreamCopy.quality(null))
        assertTrue(LiveStreamCopy.verticalNote(720).contains("about 405 pixels wide from a 720p feed"))
    }

    @Test
    fun statusReadoutAnnouncesHealth() {
        val status = LiveStreamStatusState(LiveStreamPhase.Live, 754, 3_100_000, 0, LiveStreamHealth.CONGESTED)
        assertEquals(
            "Streaming for 12 minutes 34 seconds. Sending 3.1 megabits per second. 0 dropped. Connection slow.",
            LiveStreamCopy.statusLabel(status),
        )
        assertEquals("Slow network", LiveStreamCopy.health(LiveStreamHealth.CONGESTED))
        assertEquals("Dropped 0", LiveStreamCopy.dropped(0))
    }

    @Test
    fun noticesAndConfirmations() {
        assertNull(LiveStreamCopy.notice(LiveStreamEnd.Stopped))
        assertEquals(
            "The service refused the stream: Bad key. Check the stream key and server.",
            LiveStreamCopy.notice(LiveStreamEnd.Refused("Bad key")),
        )
        assertEquals("The stream ended when the app left the screen.", LiveStreamCopy.notice(LiveStreamEnd.Background))
        assertEquals("Go live on Twitch?", LiveStreamCopy.startTitle("Twitch"))
        assertTrue(LiveStreamCopy.startMessage("720p, 30 fps, 3 Mbps", plain = true)
            .endsWith("\n\nNot encrypted: the stream and its key travel in the clear."))
        assertEquals(
            "720p, 30 fps, 3 Mbps. The camera picture goes out with the monitor LUT; assists and controls do not. " +
                "Camera recording is separate.",
            LiveStreamCopy.startMessage("720p, 30 fps, 3 Mbps", plain = false),
        )
    }

    @Test
    fun problemsFollowTheService() {
        assertEquals("Use an rtmps:// or rtmp:// address.", LiveStreamCopy.problem("notRTMPS", custom = true))
        assertEquals("Use the rtmps:// address the service gave you.", LiveStreamCopy.problem("notRTMPS", custom = false))
        assertEquals("Paste the stream key.", LiveStreamCopy.problem("emptyKey", custom = false))
    }

    @Test
    fun cardNotesFollowTheContract() {
        assertEquals("Unlock this phone to read the saved key.", LiveStreamCopy.KEY_UNAVAILABLE)
        assertEquals("Settings are locked while a stream runs.", LiveStreamCopy.LOCKED_WHILE_LIVE)
        assertEquals("Not encrypted. rtmp:// sends the picture and the stream key in the clear, so anyone on " +
            "the network path can read the key. Use rtmps:// when the service offers it.", LiveStreamCopy.PLAIN_SERVER_WARNING)
    }

    @Test
    fun livePillFollowsTheContract() {
        val service = LiveStreamServiceOption("twitch", "Twitch", "hint", false, false, false)
        val idle = LiveStreamState(services = listOf(service), selectedServiceId = "twitch")
        assertNull(liveStreamPillState(idle))
        assertNull(liveStreamPillState(idle.copy(phase = LiveStreamPhase.Ended(LiveStreamEnd.Stopped))))
        val live = LiveStreamPillState(LiveStreamPhase.Live, "Twitch", 754)
        assertEquals("LIVE 12:34", LiveStreamCopy.pillTitle(live))
        assertEquals("Live on Twitch for 12 minutes 34 seconds", LiveStreamCopy.pillLabel(live))
        val connecting = LiveStreamPillState(LiveStreamPhase.Connecting, "Twitch", 0)
        assertEquals("Connecting", LiveStreamCopy.pillTitle(connecting))
        assertEquals("Connecting to Twitch", LiveStreamCopy.pillLabel(connecting))
        val reconnecting = LiveStreamPillState(LiveStreamPhase.Reconnecting(2), "Twitch", 90)
        assertEquals("Reconnecting", LiveStreamCopy.pillTitle(reconnecting))
        assertEquals("Reconnecting to Twitch, attempt 2", LiveStreamCopy.pillLabel(reconnecting))
        assertEquals("Stop the stream to Twitch", LiveStreamCopy.pillStopLabel("Twitch"))
        assertEquals(LiveStreamPillState(LiveStreamPhase.Connecting, "Twitch", 0),
            liveStreamPillState(idle.copy(phase = LiveStreamPhase.Connecting)))
    }
}
