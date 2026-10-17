package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Session names and the values only non-DJI cameras report, named by what they are. */
class CameraLabelProfileTest {
    @Test fun nativeIsoDeclarationsPreserveUnknownAndKnownUnsupported() {
        val legacy = CameraCaptureProfile(supportsFocusMode = true)
        assertNull(legacy.nativeISO.hop)
        assertNull(legacy.nativeISO.ceiling)
        val declared = legacy.copy(nativeISO = CaptureNativeISOCapabilities(hop = false, ceiling = true))
        assertEquals(legacy.supportsFocusMode, declared.supportsFocusMode)
        assertEquals(false, declared.nativeISO.hop)
        assertEquals(true, declared.nativeISO.ceiling)
        assertEquals(legacy.component10(), declared.component10())
    }

    private val profile = CameraLabelProfile(
        shootingModeLabels = mapOf(CameraCommands.SHOOT_HYPERLAPSE to "TimeShift"),
        colorModeLabels = mapOf(CameraCommands.COLOR_NORMAL to "Standard"),
        gimbalModeLabels = mapOf(GimbalMode.FOLLOW to "Roll Lock"),
    )

    @Test fun standardProfileKeepsTheVocabularyNames() {
        assertEquals("HyperLapse", CameraCommands.shootingModeLabel(CameraCommands.SHOOT_HYPERLAPSE))
        assertEquals("Low-Light", CameraCommands.shootingModeLabel(CameraCommands.SHOOT_SUPER_NIGHT, profile = CameraLabelProfile(
            shootingModeLabels = mapOf(CameraCommands.SHOOT_SUPER_NIGHT to "Low-Light"))))
        assertEquals("Normal 8-bit", CameraCommands.colorLabel(CameraCommands.COLOR_NORMAL, profile = CameraLabelProfile(
            colorModeLabels = mapOf(CameraCommands.COLOR_NORMAL to "Normal 8-bit"))))
        assertEquals("Follow", GimbalMode.FOLLOW.label(CameraLabelProfile.standard))
        assertNull(CameraLabelProfile.standard.colorModes)
        assertEquals(FocusOption.entries.map { it.chip }, CameraLabelProfile.standard.focusLabels)
    }

    @Test fun sessionProfileOverridesOnlyItsOwnNames() {
        assertEquals("TimeShift", CameraCommands.shootingModeLabel(CameraCommands.SHOOT_HYPERLAPSE, profile = profile))
        assertEquals("Video", CameraCommands.shootingModeLabel(CameraCommands.SHOOT_VIDEO, profile = profile))
        assertEquals("Standard", CameraCommands.colorLabel(CameraCommands.COLOR_NORMAL, profile = profile))
        assertEquals("HDR", CameraCommands.colorLabel(CameraCommands.COLOR_HDR, profile = profile))
        assertEquals("Roll Lock", GimbalMode.FOLLOW.label(profile))
        assertEquals("FPV", GimbalMode.FPV.label(profile))
        val status = CameraStatus(shootingMode = CameraCommands.SHOOT_VIDEO, colorMode = CameraCommands.COLOR_NORMAL)
        assertEquals("Standard", CaptureShutterPolicy.portraitSetupCaption(status, "other", profile))
    }

    @Test fun extendedColorIsoAndSizes() {
        assertEquals("I-Log", CameraCommands.colorLabel(CameraCommands.COLOR_ILOG))
        assertEquals("Dolby Vision", CameraCommands.colorLabel(CameraCommands.COLOR_DOLBY_VISION))
        assertEquals("160", CameraCommands.isoLabel(CameraCommands.ISO_160))
        assertEquals(160, CameraCommands.isoValue(CameraCommands.ISO_160))
        assertEquals(CameraCommands.ISO_160, CameraCommands.isoIndexFromValue(160))
        assertEquals(CameraCommands.ISO_INDEX_ALL.toSet() + CameraCommands.ISO_160, CameraCommands.ISO_INDEX_BYTES)
        val sizes = listOf(
            VideoResolution.P8K to "8K", VideoResolution.P6K to "6K", VideoResolution.P4K_9X16 to "4K 9:16",
            VideoResolution.P3K to "3K", VideoResolution.P8K_235 to "8K 2.35:1", VideoResolution.P4K_235 to "4K 2.35:1",
        )
        for ((size, label) in sizes) assertEquals(label, size.label)
        assertEquals(listOf(0xD0, 0xD1, 0xD3, 0xD4, 0xD5, 0xD6), sizes.map { it.first.rawValue })
        assertEquals(VideoAspect.NINE_SIXTEEN, VideoResolution.P4K_9X16.aspect)
        assertNull(VideoResolution.P8K_235.aspect)
    }
}
