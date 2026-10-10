package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.*
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import kotlin.test.*

class CaptureProfileAdmissionTest {
    @Test fun unknownFormatCannotOfferAnInventedResolutionOrRate() {
        assertTrue(CaptureLists.modeTabs(LiveSheet.FORMAT, expoMode = -1, offersIsoAuto = false).isEmpty())
        val unknown = CameraStatus(availableVideoFormats = listOf(VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS30)))
        assertNull(VideoFormat.current(unknown))
        assertNull(recordingCategoryQuickControl(LiveSheet.FORMAT, unknown))
        val partial = unknown.copy(resolutionCode = VideoResolution.P4K.rawValue)
        val control = recordingCategoryQuickControl(LiveSheet.FORMAT, partial)
        assertEquals(listOf("30p"), control?.options)
        assertEquals("", control?.selection)
        assertNull(VideoFormat.current(partial))
        assertEquals(VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS30),
            CaptureLists.nextVideoFormat(partial, 0, "30p", true))
    }

    @Test fun profileKeepsILogAndDolbyVisionInTheSharedColorDrum() {
        val colors = listOf(CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_ILOG, CameraCommands.COLOR_DOLBY_VISION)
        val profile = CameraLabelProfile(colorModeLabels = mapOf(CameraCommands.COLOR_NORMAL to "Standard"), colorModes = colors)
        for (color in colors) {
            val status = CameraStatus(colorMode = color, availableColorModes = colors)
            val control = recordingCategoryQuickControl(LiveSheet.COLOR, status, profile = profile)
            assertEquals(listOf("Standard", "I-Log", "Dolby Vision"), control?.options)
            assertEquals(CameraCommands.colorLabel(color, profile = profile), control?.selection)
        }
    }

    @Test fun unknownProfileHasNoMadeUpIsoFloorOrFocusPermission() {
        assertNull(CameraModel("Osmo Pocket 3").captureProfile)
        assertTrue(CaptureLists.isoAutoLabels(CameraStatus(colorMode = CameraCommands.COLOR_NORMAL)).isEmpty())
        assertFalse(CaptureLists.supportsFocusModeOrDefault(null))
        assertFalse(CaptureLists.supportsFocusModeOrDefault(CameraModel("Osmo Pocket 3")))
    }

    @Test fun optionalAudioContainsOnlyDeclaredFieldsAndUnknownSelection() {
        val field = CaptureAudioField(CaptureAudioControl.CHANNEL, "Channel",
            listOf(CaptureAudioValue.Channel(CaptureAudioChannel.STEREO), CaptureAudioValue.Channel(CaptureAudioChannel.MONO)))
        val service = CaptureAudioService(CaptureAudioSourceID(CameraSessionID(), ControlEpoch()), listOf(field), { CaptureAudioCommitResult.SUBMITTED }, {})
        assertEquals(listOf("Channel"), service.fields.map { it.title })
        assertEquals(listOf("Stereo", "Mono"), field.choices.map { it.label })
        assertNull(field.observed)
    }
}
