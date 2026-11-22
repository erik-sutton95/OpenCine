package com.opencapture.opencine.media3

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class Media3ReferenceFramesTest {
    @Test fun textureMustHaveTheExactNativeStampOfAnAdmittedFrame() {
        val previous = Media3ReferenceFrames.Frame(1_000_000L, 5_000_000_000L)
        val current = Media3ReferenceFrames.Frame(1_040_000L, 5_040_000_000L)
        val picture = Media3ReferenceFrames.Snapshot(2L, listOf(current))
        assertEquals(current, picture.frame(current.releaseNs))
        assertEquals(current, picture.frame(current.presentationUs * 1_000L))
        assertNull(picture.frame(previous.releaseNs))
        assertNull(picture.frame(current.releaseNs - 1L))
        assertNull(picture.frame(0L))
        val first = Media3ReferenceFrames.Frame(0L, 5_080_000_000L)
        assertEquals(first, Media3ReferenceFrames.Snapshot(3L, listOf(first)).frame(0L))
    }
}
