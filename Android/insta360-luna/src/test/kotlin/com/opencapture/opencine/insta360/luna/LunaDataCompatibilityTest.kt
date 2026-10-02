package com.opencapture.opencine.insta360.luna

import kotlin.test.assertEquals
import org.junit.Test

class LunaDataCompatibilityTest {
    /** Installed OpenInstaCine builds keep their camera authorization identity under this name. */
    @Test fun defaultClientIdentityPreferencesKeepsTheShippedName() {
        assertEquals("openinstacine.client-identity", LunaBackend.DEFAULT_CLIENT_IDENTITY_PREFERENCES)
    }
}
