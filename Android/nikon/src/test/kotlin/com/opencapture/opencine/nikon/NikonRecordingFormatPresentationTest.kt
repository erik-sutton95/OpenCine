package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NikonRecordingFormatPresentationTest {
    @Test fun groupingRetainsTheExactCropAwareWriteToken() {
        val fx = NikonRecordingFormatPresentation.fromToken("[FX] 4K · 25p")
        val dx = NikonRecordingFormatPresentation.fromToken("[DX] 4K · 25p")
        assertEquals("FX", fx.imageArea); assertEquals("DX", dx.imageArea)
        assertEquals(fx.resolution, dx.resolution)
        assertEquals(fx.frameRate, dx.frameRate)
        assertEquals("[DX] 4K · 25p", dx.token)
        assertEquals("4K", dx.resolution); assertEquals("25p", dx.frameRate)
    }

    @Test fun genericModesNeverAcquireAnImageArea() {
        val generic = NikonRecordingFormatPresentation.fromToken("1920 · 60p")
        assertNull(generic.imageArea)
        assertEquals("1920", generic.resolution); assertEquals("60p", generic.frameRate)
    }

    @Test fun unknownShapesRemainExactUnclassifiedChoices() {
        for (token in listOf("[future] 4K · 25p", "future exact token", "4K · unknown", "0 · 0p")) {
            val choice = NikonRecordingFormatPresentation.fromToken(token)
            assertEquals(token, choice.token)
            assertNull(choice.imageArea); assertNull(choice.resolution); assertNull(choice.frameRate)
        }
    }
}
