package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class MediaStoreInsertPolicyTest {
    private val policy = MediaStoreInsertPolicy("Album")

    @Test
    fun photosAreNeverPlacedUnderMovies() {
        // Play #348: Images collection + RELATIVE_PATH Movies/... is rejected by
        // MediaProvider with IllegalArgumentException.
        for (mime in listOf("image/jpeg", "image/heic", "image/x-adobe-dng")) {
            assertFalse(
                policy.relativePath(mime).startsWith("Movies"),
                "$mime must not be inserted under Movies",
            )
        }
        assertEquals("Movies/Album", policy.relativePath("video/mp4"))
    }

    @Test
    fun displayNameStripsPathSeparatorsAndControlChars() {
        assertEquals("a_b.jpg", policy.sanitizeDisplayName("a/b.jpg"))
        assertEquals("a_b.jpg", policy.sanitizeDisplayName("a\u0000b.jpg"))
        assertEquals("clip.mp4", policy.sanitizeDisplayName("  clip.mp4  "))
    }

    @Test
    fun displayNameFallsBackWhenEmpty() {
        assertEquals("Album_media", policy.fallbackName)
        assertEquals(policy.fallbackName, policy.sanitizeDisplayName(""))
        assertEquals(policy.fallbackName, policy.sanitizeDisplayName("   "))
    }
}
