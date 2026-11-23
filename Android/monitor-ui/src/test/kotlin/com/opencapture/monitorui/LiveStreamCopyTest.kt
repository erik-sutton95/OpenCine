package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
    fun upscaledQualityLineSaysUpscaled() {
        val upscaled = LiveStreamQuality(1920, 1080, 30.0, 6_000_000, LiveStreamQualityKind.UPSCALED)
        assertEquals("1080p upscaled, 30 fps, 6 Mbps", LiveStreamCopy.quality(upscaled))
        assertEquals(
            "1080p vertical upscaled, 30 fps, 6 Mbps",
            LiveStreamCopy.quality(LiveStreamQuality(1080, 1920, 30.0, 6_000_000, LiveStreamQualityKind.UPSCALED)),
        )
        assertTrue(LiveStreamCopy.startMessage(LiveStreamCopy.quality(upscaled), plain = false).startsWith("1080p upscaled, 30 fps"))
    }

    @Test
    fun qualityPickerShowsOnlyWithChoices() {
        val feed = LiveStreamQualityOption("cameraFeed", LiveStreamCopy.QUALITY_CAMERA_FEED)
        val upscaled = LiveStreamQualityOption("upscaled1080p", LiveStreamCopy.QUALITY_UPSCALED, LiveStreamCopy.QUALITY_UPSCALED_DETAIL)
        assertFalse(LiveStreamState().showsQualityPicker)
        assertFalse(LiveStreamState(qualityOptions = listOf(feed)).showsQualityPicker)
        val both = LiveStreamState(qualityOptions = listOf(feed, upscaled))
        assertTrue(both.showsQualityPicker)
        assertNull(both.qualityDetail)
        val chosen = both.copy(selectedQualityId = "upscaled1080p")
        assertEquals("1080p upscaled", chosen.selectedQuality?.title)
        assertEquals("The camera feed scaled up to 1080p, with your LUT.", chosen.qualityDetail)
        val unavailable = LiveStreamQualityOption("x", "X", unavailableReason = "Not now.")
        assertFalse(unavailable.enabled)
        assertEquals("Not now.", LiveStreamState(qualityOptions = listOf(feed, unavailable), selectedQualityId = "x").qualityDetail)
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

    @Test
    fun cameraQualityLineAndStartMessageSayWhatGoesOut() {
        val camera = LiveStreamQuality(1920, 1080, 30.0, 6_000_000, LiveStreamQualityKind.CAMERA)
        assertEquals("1080p from camera, 30 fps, 6 Mbps", LiveStreamCopy.quality(camera))
        assertEquals(
            "1080p from camera, 30 fps, 6 Mbps. The camera's own picture goes out in standard color, without the " +
                "monitor LUT, with the camera's sound. Camera recording is separate.",
            LiveStreamCopy.startMessage(camera, plain = false),
        )
        assertEquals("1080p from camera", LiveStreamCopy.QUALITY_CAMERA)
        assertEquals("Sharper picture, encoded by the camera, standard color, no LUT.", LiveStreamCopy.QUALITY_CAMERA_DETAIL)
        assertEquals("Save a shared network in the camera's Wi-Fi setup to use this.", LiveStreamCopy.QUALITY_CAMERA_NEEDS_NETWORK)
        assertEquals("Go live over es_iphone16", LiveStreamCopy.startOnNetwork("es_iphone16"))
    }

    @Test
    fun cameraStatusLinesAndRetry() {
        assertEquals("Starting the camera's stream.", LiveStreamCopy.cameraStatus(LiveStreamCameraStatus.STARTING))
        assertEquals(
            "1080p from camera. Assists, scopes and camera controls are off in this mode.",
            LiveStreamCopy.cameraStatus(LiveStreamCameraStatus.LIVE),
        )
        assertEquals("The camera's stream stopped. Trying again.", LiveStreamCopy.cameraStatus(LiveStreamCameraStatus.RECOVERING))
        assertEquals("The camera's stream did not come back.", LiveStreamCopy.cameraStatus(LiveStreamCameraStatus.LOST))
        assertEquals(
            "The camera is not responding. Hold its power button about 10 seconds to restart it.",
            LiveStreamCopy.cameraStatus(LiveStreamCameraStatus.NOT_RESPONDING),
        )
        assertEquals(
            listOf(LiveStreamCameraStatus.LOST, LiveStreamCameraStatus.NOT_RESPONDING),
            LiveStreamCameraStatus.entries.filter { it.offersRetry },
        )
        assertEquals("Retry", LiveStreamCopy.CAMERA_RETRY)
        assertEquals(
            "The camera did not start its stream. Try again, or choose Camera feed in the live stream settings.",
            LiveStreamCopy.notice(LiveStreamEnd.CameraDidNotStart),
        )
        assertEquals(
            "The camera stopped responding. Hold its power button about 10 seconds to restart it, then go live again.",
            LiveStreamCopy.notice(LiveStreamEnd.CameraNotResponding),
        )
    }
}
