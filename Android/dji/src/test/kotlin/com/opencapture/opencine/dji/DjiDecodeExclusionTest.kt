package com.opencapture.opencine.dji

import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.VideoFormat
import com.opencapture.opencine.vocabulary.VideoFrameRate
import com.opencapture.opencine.vocabulary.VideoResolution
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The vocabulary's non-DJI values (ISO 160, Dolby Vision, the 8K/6K/... sizes) never come out of DJI decode. */
class DjiDecodeExclusionTest {
    private val nonDjiSizes = listOf(0xD0, 0xD1, 0xD3, 0xD4, 0xD5, 0xD6)

    @Test fun isoLadderLeavesOut160() {
        val camcap = byteArrayOf(0x01, 0x05, 0x00, 0x00, 0x03, 0x03, 0xE0.toByte(), 0x04)
        assertEquals(listOf(0x03, 0x04), CameraCommands.parseIsoIndices(camcap))
        assertEquals(-1, CameraCommands.djiIsoIndex(CameraCommands.ISO_160))
        assertEquals(0x04, CameraCommands.djiIsoIndex(0x04))
        val expo = ByteArray(8).also { it[5] = 0xE0.toByte(); it[7] = CameraCommands.EXPO_MANUAL.toByte() }
        assertEquals(-1, StatusExtras.applyExpo(expo, CameraStatus()).isoIndex)
        assertEquals(ISOValue.Auto, DjiCameraSessionAdapter.iso(CameraCommands.ISO_160))
        assertNull(DjiCameraSessionAdapter.isoIndex(ISOValue.Manual(160)))
        assertEquals(0x03, DjiCameraSessionAdapter.isoIndex(ISOValue.Manual(100)))
    }

    @Test fun colorTableLeavesOutDolbyVision() {
        assertEquals(-1, CameraCommands.parseColorMode(CameraCommands.COLOR_DOLBY_VISION))
        assertEquals(-1, CameraCommands.parseColorMode(CameraCommands.COLOR_DOLBY_VISION, "Osmo Pocket 3"))
        assertEquals(CameraCommands.COLOR_DLOG, CameraCommands.parseColorMode(CameraCommands.COLOR_DLOG))
    }

    @Test fun formatTablesLeaveOutNonDjiSizes() {
        val fps = VideoFrameRate.FPS30.rawValue
        for (res in nonDjiSizes) {
            assertNull(VideoFormat.parseVideoParamV2(byteArrayOf(res.toByte(), fps.toByte())))
            assertEquals(-1, StatusExtras.applyVideo(byteArrayOf(res.toByte(), fps.toByte()), CameraStatus()).resolutionCode)
        }
        val list = byteArrayOf(0x01, 0x07, 0x00, 0x02, 0xD0.toByte(), fps.toByte(), 0x00, 0x10, fps.toByte(), 0x00)
        assertEquals(listOf(VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS30)), CameraCommands.parseVideoFormats(list))
    }
}
