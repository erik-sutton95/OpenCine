package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.CameraValuePin
import com.opencapture.opencine.media.ExtraMirrorHold
import com.opencapture.opencine.media.FeedPresentPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CameraControlTest {
    @Test
    fun emptyCapabilityPortraitKeepsReportedResolution() {
        val current = VideoFormat(VideoResolution.P3K_9X16, VideoFrameRate.FPS25)
        val formats = VideoFormat.pickerFormats(emptyList(), CameraModel("Osmo Pocket 3"), -1)
        val aspects = VideoFormat.aspects(formats, current.resolution.aspect)
        val resolutions = VideoFormat.resolutions(
            formats, current.resolution,
            if (aspects.size > 1) VideoAspect.NINE_SIXTEEN else null,
        )
        assertEquals(listOf(VideoResolution.P3K_9X16), resolutions)
        assertEquals(listOf("3K"), resolutions.map { it.tabTitle })
    }

    @Test
    fun emptyCapabilityPreservesReportedSizesWithoutInventingAnAspect() {
        for (current in listOf(
            VideoResolution.P3K_1X1, VideoResolution.P2_7K,
            VideoResolution.P4K_4X3, VideoResolution(0xFE),
        )) {
            assertEquals(listOf(current), VideoFormat.resolutions(emptyList(), current))
        }
        assertEquals(listOf(VideoResolution.P1080, VideoResolution.P4K), VideoFormat.resolutions(emptyList(), null))
        assertTrue(VideoFormat.resolutions(emptyList(), VideoResolution.P3K_9X16, VideoAspect.SIXTEEN_NINE).isEmpty())
    }

    @Test
    fun isoStepsSkipAutoAndStopAtEnds() {
        assertEquals(0x04, CameraCommands.isoStepped(0x03, 1, CameraCommands.ISO_INDEX_ALL))
        assertNull(CameraCommands.isoStepped(0x0B, 1, CameraCommands.ISO_INDEX_ALL))
        assertNull(CameraCommands.isoStepped(0x00, 1, CameraCommands.ISO_INDEX_ALL))
        assertEquals(0x04, CameraCommands.isoStepped(0x05, -1, listOf(0x04, 0x05, 0x06)))
    }

    @Test
    fun shutterStepsOpenTowardSlower() {
        val denoms = listOf(16_000, 8_000, 100, 50, 25, 4)
        assertEquals(25, CameraCommands.shutterSteppedDenom(50, 1, denoms))
        assertEquals(100, CameraCommands.shutterSteppedDenom(50, -1, denoms))
        assertNull(CameraCommands.shutterSteppedDenom(16_000, -1, denoms))
        assertNull(CameraCommands.shutterSteppedDenom(4, 1, denoms))
        assertEquals(25, CameraCommands.shutterSteppedDenom(48, 1, denoms))
    }

    @Test
    fun whiteBalanceCustomClampMatchesIos() {
        assertEquals(2_000 to 0, CameraCommands.clampWhiteBalanceCustom(1999, 0))
        assertEquals(10_000 to 100, CameraCommands.clampWhiteBalanceCustom(12_000, 140))
        assertEquals(5_600 to -100, CameraCommands.clampWhiteBalanceCustom(5_600, -140))
        val extra = CameraCommands.clampWhiteBalanceCustom(3200, -5)
        assertEquals("3200\u001f-5", "${extra.first}\u001f${extra.second}")
    }

    @Test
    fun videoFormatParsesHighRateRawAndDrumLabels() {
        assertEquals(
            VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS120),
            VideoFormat.parse(CameraCommands.RES_4K, 7),
        )
        assertEquals(VideoResolution.P1080_4X3, VideoResolution.fromRaw(0x0C))
        assertEquals(VideoFrameRate.FPS120, VideoFrameRate.fromDrumLabel("120p"))
    }

    @Test
    fun formatPinHoldsOptimisticUntilSubscribeMatches() {
        val expected = VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS25)
        val pin = FormatPin(expected, deadlineElapsedRealtime = 2_000L)
        val stale =
            CameraStatus(
                fps = 24,
                resolutionCode = CameraCommands.RES_1080,
                fpsIndex = 1,
            )
        val held = VideoFormat.absorbStale(stale, pin, nowElapsedRealtime = 500L)
        assertEquals(CameraCommands.RES_4K, held.first.resolutionCode)
        assertEquals(2, held.first.fpsIndex)
        assertEquals(25, held.first.fps)
        assertEquals(pin, held.second)
        val matched =
            VideoFormat.absorbStale(
                CameraStatus(fps = 25, resolutionCode = CameraCommands.RES_4K, fpsIndex = 2),
                pin,
                nowElapsedRealtime = 500L,
            )
        assertNull(matched.second)
        assertEquals(25, matched.first.fps)
        val expired = VideoFormat.absorbStale(stale, pin, nowElapsedRealtime = 2_000L)
        assertNull(expired.second)
        assertEquals(CameraCommands.RES_1080, expired.first.resolutionCode)
        val optimistic =
            CameraStatus(
                fps = 25,
                resolutionCode = CameraCommands.RES_4K,
                fpsIndex = 2,
            )
        val copy =
            VideoFormat.absorbStale(
                optimistic,
                pin,
                nowElapsedRealtime = 500L,
                formatReported = false,
            )
        assertEquals(pin, copy.second)
        assertEquals(CameraCommands.RES_4K, copy.first.resolutionCode)
        assertEquals(2, copy.first.fpsIndex)
    }

    @Test
    fun expoPinHoldsOptimisticModeUntilSubscribeMatches() {
        val pin =
            ExpoPin(expoMode = CameraCommands.EXPO_AUTO, deadlineElapsedRealtime = 2_000L)
        val current = CameraStatus(expoMode = CameraCommands.EXPO_AUTO)
        val stale = CameraStatus(expoMode = CameraCommands.EXPO_MANUAL)
        val held = pin.absorb(stale, current, nowElapsedRealtime = 500L)
        assertEquals(CameraCommands.EXPO_AUTO, held.first.expoMode)
        assertEquals(pin.expoMode, held.second?.expoMode)
        val matched =
            pin.absorb(
                CameraStatus(expoMode = CameraCommands.EXPO_AUTO),
                current,
                nowElapsedRealtime = 500L,
            )
        assertNull(matched.second)
        assertEquals(CameraCommands.EXPO_AUTO, matched.first.expoMode)
        val expired = pin.absorb(stale, current, nowElapsedRealtime = 2_000L)
        assertNull(expired.second)
        assertEquals(CameraCommands.EXPO_MANUAL, expired.first.expoMode)
    }

    @Test
    fun colorPinHoldsOptimisticUntilSubscribeMatches() {
        val pin = ColorPin(CameraCommands.COLOR_DLOG, deadlineElapsedRealtime = 2_000L)
        val stale = CameraStatus(colorMode = CameraCommands.COLOR_DLOG2)
        val held = ColorPin.absorbStale(stale, pin, nowElapsedRealtime = 500L)
        assertEquals(CameraCommands.COLOR_DLOG, held.first.colorMode)
        assertEquals(pin, held.second)
        val matched =
            ColorPin.absorbStale(
                CameraStatus(colorMode = CameraCommands.COLOR_DLOG),
                pin,
                nowElapsedRealtime = 500L,
            )
        assertNull(matched.second)
        assertEquals(CameraCommands.COLOR_DLOG, matched.first.colorMode)
        val expired = ColorPin.absorbStale(stale, pin, nowElapsedRealtime = 2_000L)
        assertNull(expired.second)
        assertEquals(CameraCommands.COLOR_DLOG2, expired.first.colorMode)
        val merged =
            ColorPin.absorbStale(
                CameraStatus(colorMode = CameraCommands.COLOR_DLOG),
                pin,
                nowElapsedRealtime = 500L,
                reported = false,
            )
        assertEquals(pin, merged.second)
        assertEquals(CameraCommands.COLOR_DLOG, merged.first.colorMode)
    }

    @Test
    fun shootingModePinIgnoresUnrelatedFramesAndStaleEcho() {
        val pin =
            ShootingModePin(
                expected = CameraCommands.SHOOT_SLOWMO,
                deadlineElapsedRealtime = 2_000L,
            )
        val merged =
            ShootingModePin.absorbStale(
                CameraStatus(shootingMode = CameraCommands.SHOOT_SLOWMO),
                pin,
                nowElapsedRealtime = 500L,
                reported = false,
            )
        assertEquals(pin, merged.second)
        val stale =
            ShootingModePin.absorbStale(
                CameraStatus(shootingMode = CameraCommands.SHOOT_VIDEO),
                pin,
                nowElapsedRealtime = 500L,
                reported = true,
            )
        assertEquals(CameraCommands.SHOOT_SLOWMO, stale.first.shootingMode)
        assertEquals(pin, stale.second)
        val matched =
            ShootingModePin.absorbStale(
                CameraStatus(shootingMode = CameraCommands.SHOOT_SLOWMO),
                pin,
                nowElapsedRealtime = 500L,
                reported = true,
            )
        assertNull(matched.second)
        assertEquals(CameraCommands.SHOOT_SLOWMO, matched.first.shootingMode)
        val expired =
            ShootingModePin.absorbStale(
                CameraStatus(shootingMode = CameraCommands.SHOOT_VIDEO),
                pin,
                nowElapsedRealtime = 2_000L,
                reported = true,
            )
        assertNull(expired.second)
        assertEquals(CameraCommands.SHOOT_VIDEO, expired.first.shootingMode)
    }

    @Test
    fun audioPinHoldsUntilMatchingSnapshot() {
        val current =
            CameraStatus(
                audioChannel = CameraCommands.AUDIO_SPATIAL,
                vocalBoost = 1,
                windNr = 1,
                directionalAudio = 1,
            )
        val stale =
            CameraStatus(
                audioChannel = CameraCommands.AUDIO_STEREO,
                vocalBoost = 0,
                windNr = 0,
                directionalAudio = 0,
            )
        val pin =
            AudioPin(
                channel = CameraCommands.AUDIO_SPATIAL,
                vocal = 1,
                wind = 1,
                directional = 1,
                deadlineElapsedMs = 2_000,
            )
        val (held, pending) = pin.absorb(stale, current, nowElapsedMs = 0)
        assertEquals(CameraCommands.AUDIO_SPATIAL, held.audioChannel)
        assertEquals(1, held.vocalBoost)
        assertEquals(1, held.windNr)
        assertEquals(1, held.directionalAudio)
        assertEquals(CameraCommands.AUDIO_SPATIAL, pending?.channel)
        assertEquals(1, pending?.vocal)
        assertEquals(1, pending?.wind)
        assertEquals(1, pending?.directional)

        val (caught, cleared) = pin.absorb(current, current, nowElapsedMs = 0)
        assertEquals(CameraCommands.AUDIO_SPATIAL, caught.audioChannel)
        assertNull(cleared)

        val (expired, dropped) = pin.absorb(stale, current, nowElapsedMs = AudioPin.TTL_MS)
        assertEquals(CameraCommands.AUDIO_STEREO, expired.audioChannel)
        assertEquals(0, expired.windNr)
        assertNull(dropped)
    }

    @Test
    fun extraMirrorHoldsThreePresentsThenCommits() {
        assertTrue(FeedPresentPolicy.shouldHoldPictureAcrossMirror(1, 0.04))
        assertTrue(FeedPresentPolicy.shouldHoldPictureAcrossMirror(3, 0.12))
        assertTrue(!FeedPresentPolicy.shouldHoldPictureAcrossMirror(4, 0.16))
        assertTrue(!FeedPresentPolicy.shouldHoldPictureAcrossMirror(1, 0.2))
        val hold = ExtraMirrorHold()
        assertEquals(ExtraMirrorHold.Step.COMMIT, hold.step(false, 0.0).step)
        assertEquals(ExtraMirrorHold.Step.UNCHANGED, hold.step(false, 0.04).step)
        assertEquals(ExtraMirrorHold.Step.HOLD, hold.step(true, 0.08).step)
        assertEquals(ExtraMirrorHold.Step.HOLD, hold.step(true, 0.12).step)
        assertEquals(ExtraMirrorHold.Step.HOLD, hold.step(true, 0.16).step)
        val commit = hold.step(true, 0.20)
        assertEquals(ExtraMirrorHold.Step.COMMIT, commit.step)
        assertEquals(true, commit.mirrored)
        hold.reset()
        assertEquals(ExtraMirrorHold.Step.COMMIT, hold.step(true, 1.0).step)
    }

    @Test
    fun emptyShutterCapUsesDocumentedVideoLadder() {
        val wheel = CameraCommands.shutterWheelDenoms(emptyList(), 60)
        assertTrue(wheel.contains(60))
        assertTrue(wheel.contains(50))
        assertTrue(wheel.contains(48))
        assertTrue(wheel.contains(8000))
        assertEquals(8000, wheel.first())
        assertEquals(48, ShutterAngle.denom(180.0, 24, wheel))
        val withOdd = CameraCommands.shutterWheelDenoms(emptyList(), 80)
        assertTrue(withOdd.contains(80))
        assertTrue(withOdd.contains(100))
    }

    @Test
    fun controlHudTimeoutStaysOffTheHudLikeIos() {
        assertEquals(null, ControlHud.timeoutNote("Color", announce = false))
        assertEquals(null, ControlHud.timeoutNote("ISO limit GET", announce = false))
        assertEquals(null, ControlHud.timeoutNote("Audio ch GET", announce = false))
        assertEquals("Color timed out", ControlHud.timeoutNote("Color", announce = true))
        assertEquals("ISO limit GET timed out", ControlHud.timeoutNote("ISO limit GET", announce = true))
        assertEquals(222.0, ControlHud.toastCenterY(200.0))
        assertEquals(82.0, ControlHud.toastCenterY(0.0, 60.0))
        assertEquals(222.0, ControlHud.toastCenterY(200.0, null))
        assertEquals(72.0, ControlHud.toastCenterY(50.0, 50.0))
        assertEquals(72.0, ControlHud.toastCenterY(50.0, 40.0))
        assertTrue(!ControlHud.RECORDING_COLOR_LOCK_NOTE.contains("0x"))
    }

    @Test fun dependentAngleHasABoundedConfirmationWindowAndDirectSpeedCancelsIt() {
        val expected = VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS60)
        val previous = CameraStatus(resolutionCode = VideoResolution.P4K.rawValue,
            fpsIndex = VideoFrameRate.FPS24.rawValue, fps = 24)
        val pin = FormatPin(expected, deadlineElapsedRealtime = 2_000, shutterAngle = 180.0)
        assertNotNull(VideoFormat.absorbStale(previous, pin, 2_100).second)
        assertNotNull(VideoFormat.absorbStale(previous, pin, 7_999).second)
        assertNull(VideoFormat.absorbStale(previous, pin, 8_000).second)
        pin.shutterAngle = null
        assertNull(VideoFormat.absorbStale(previous, pin, 2_100).second)
    }
}
