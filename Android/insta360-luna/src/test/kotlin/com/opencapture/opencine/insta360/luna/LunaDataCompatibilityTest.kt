package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.EncodedVideoFrame
import kotlin.test.assertNull
import kotlin.test.assertEquals
import org.junit.Test

class LunaDataCompatibilityTest {
    @Test fun oldFrameConstructorKeepsUnknownSourceAndCopiesRetainCapturedOwnership() {
        assertNull(EncodedVideoFrame(byteArrayOf(1), 100).connectionGeneration)
        val captured = EncodedVideoFrame(byteArrayOf(1), 100, 7L)
        assertEquals(7L, captured.copy(timestampMicros = 200).connectionGeneration)
    }

    /** Installed OpenInstaCine builds keep their camera authorization identity under this name. */
    @Test fun defaultClientIdentityPreferencesKeepsTheShippedName() {
        assertEquals("openinstacine.client-identity", LunaBackend.DEFAULT_CLIENT_IDENTITY_PREFERENCES)
    }
}
