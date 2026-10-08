package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.*
import kotlin.test.*

class DjiCapturePolicyGoldenTest {
    private val action6 = "Osmo Action 6"
    @Test fun captureBytes() {
        assertEquals(CameraCommands.SHOOT_PHOTO, CameraCommands.photoModeRaw(action6))
        assertEquals(
            CaptureShutterPolicy.CaptureKind.SHUTTER_TRIGGER,
            CaptureShutterPolicy.captureKind(CameraCommands.SHOOT_TIMELAPSE, action6),
        )
        assertEquals(
            CaptureShutterPolicy.CaptureKind.VIDEO_RECORD,
            CaptureShutterPolicy.captureKind(CameraCommands.SHOOT_TIMELAPSE, "Osmo Pocket 4"),
        )
    }


    @Test fun shutterTriggerKeepsQualifiedModelsAndOriginalBytes() {
        assertTrue(
            CaptureShutterPolicy.usesShutterTriggerOnPocket3(
                CameraCommands.SHOOT_TIMELAPSE, "Osmo Pocket 3",
            ),
        )
        assertFalse(
            CaptureShutterPolicy.usesShutterTriggerOnPocket3(
                CameraCommands.SHOOT_TIMELAPSE, "Osmo Pocket 4 Pro",
            ),
        )
        assertFalse(
            CaptureShutterPolicy.usesShutterTriggerOnPocket3(
                CameraCommands.SHOOT_HYPERLAPSE, "Osmo Pocket 3",
            ),
        )
        assertEquals("1", CaptureShutterPolicy.shootPhotoExtra(start = true))
        assertEquals("0", CaptureShutterPolicy.shootPhotoExtra(start = false))
        assertEquals(
            CaptureShutterPolicy.CaptureKind.SHUTTER_TRIGGER,
            CaptureShutterPolicy.captureKind(CameraCommands.SHOOT_TIMELAPSE, "Osmo Pocket 3"),
        )
        assertEquals(
            CaptureShutterPolicy.CaptureKind.VIDEO_RECORD,
            CaptureShutterPolicy.captureKind(CameraCommands.SHOOT_TIMELAPSE, "Osmo Pocket 4 Pro"),
        )
        assertEquals(
            CaptureShutterPolicy.CaptureKind.VIDEO_RECORD,
            CaptureShutterPolicy.captureKind(CameraCommands.SHOOT_SUPER_NIGHT, "Osmo Pocket 3"),
        )
        assertEquals(
            CaptureShutterPolicy.CaptureKind.PHOTO,
            CaptureShutterPolicy.captureKind(CameraCommands.SHOOT_PHOTO, "Osmo Pocket 3"),
        )
    }

    @Test fun modelQualificationKeepsOriginalPositiveAndNegativeCases() {
        assertTrue(CameraModel.looksLikePocket4Pro("Osmo Pocket 4 Pro"))
        assertTrue(CameraModel.looksLikePocket4Pro("OsmoPocket4P-ABCD"))
        assertFalse(CameraModel.looksLikePocket4Pro("Osmo Pocket 4"))
        assertFalse(CameraModel.looksLikePocket4Pro("Hero4Pro"))
        assertTrue(CameraModel.supportsSlowMoFormatTrailer("OsmoPocket4P-ABCD"))
        assertFalse(CameraModel.supportsSlowMoFormatTrailer("Osmo Pocket 4"))
    }

    @Test
    fun pocket3PickerFallbackIncludesNormalVideoSizesOnly() {
        val value = CameraModel(name = "Osmo Pocket 3", family = "pocket")
        val model = value.copy(captureProfile = DjiCaptureCapabilityProfile.make(value))
        val formats = VideoFormat.pickerFormats(emptyList(), model, CameraCommands.SHOOT_VIDEO)
        assertTrue(VideoFormat.resolutions(formats, VideoResolution.P4K, VideoAspect.SIXTEEN_NINE).contains(VideoResolution.P2_7K))
        assertTrue(VideoFormat.resolutions(formats, null, VideoAspect.ONE_ONE).contains(VideoResolution.P3K_1X1))
        assertTrue(formats.none { it.resolution.aspect == VideoAspect.NINE_SIXTEEN })
        assertTrue(
            !VideoFormat.allowsOperatorSet(
                VideoFormat(VideoResolution.P3K_9X16, VideoFrameRate.FPS25),
                emptyList(),
                model,
                CameraCommands.SHOOT_VIDEO,
            ),
        )
        assertTrue(!VideoFormat.aspects(formats, null).contains(VideoAspect.FOUR_THREE))
        val reported = listOf(VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS25))
        assertEquals(reported, VideoFormat.pickerFormats(reported, model, 1))
        for (mode in listOf(-1, 2, 26)) {
            assertTrue(VideoFormat.pickerFormats(emptyList(), model, mode).isEmpty())
        }
        for (name in listOf("Osmo Pocket 4 Pro", "Osmo Nano", "Unknown")) {
            assertTrue(VideoFormat.pickerFormats(emptyList(), CameraModel(name), 1).isEmpty())
        }
    }

}
