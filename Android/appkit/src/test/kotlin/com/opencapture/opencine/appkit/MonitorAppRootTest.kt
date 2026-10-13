package com.opencapture.opencine.appkit

import androidx.lifecycle.ViewModelStore
import com.opencapture.opencine.core.ConnectTarget
import com.opencapture.opencine.core.IntegrationID
import com.opencapture.opencine.core.NearbyCamera
import androidx.lifecycle.ViewModelStoreOwner
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class MonitorAppRootTest {
    @Test
    fun manifestCheckNamesEveryUndeclaredFlag() {
        val manifest =
            "<application>\n" +
            "  <activity android:name=\".Other\" android:configChanges=\"orientation\" />\n" +
            "  <activity\n" +
            "      android:name=\".MainActivity\"\n" +
            "      android:configChanges=\"orientation|screenSize|screenLayout|keyboardHidden\">\n" +
            "  </activity>\n" +
            "</application>"
        assertEquals(
            listOf("smallestScreenSize", "keyboard", "navigation", "uiMode", "density", "fontScale"),
            MonitorActivityConfigChanges.missingIn(manifest, ".MainActivity"),
        )
        val complete = """<activity android:name=".MainActivity" android:configChanges="${MonitorActivityConfigChanges.REQUIRED.joinToString("|")}"/>"""
        assertEquals(emptyList(), MonitorActivityConfigChanges.missingIn(complete, ".MainActivity"))
        assertNull(MonitorActivityConfigChanges.missingIn(manifest, ".Missing"))
    }

    private class Root : AutoCloseable {
        var closed = 0
        override fun close() { closed += 1 }
    }

    @Test
    fun retainedRootSurvivesRecreationAndClosesWhenTheActivityFinishes() {
        val store = ViewModelStore()
        // A recreated activity gets the same ViewModelStore; a finished one clears it.
        val first = object : ViewModelStoreOwner { override val viewModelStore = store }
        val recreated = object : ViewModelStoreOwner { override val viewModelStore = store }
        var created = 0
        val root = first.retainedMonitorRoot { created += 1; Root() }
        assertSame(root, recreated.retainedMonitorRoot { created += 1; Root() })
        assertEquals(1, created)
        assertEquals(0, root.closed)
        store.clear()
        assertEquals(1, root.closed)
        assertTrue(first.retainedMonitorRoot { Root() } !== root)
    }

    @Test
    fun discoveryRestartWaitsForIdleOnlyWhenTheIntegrationSaysSo() {
        val idle = CamerasModel.State()
        val id = IntegrationID("test.cameras")
        val camera = NearbyCamera("cam", name = "CAM", model = "Test Body", routes = emptySet())
        val connecting = CamerasModel.State(attempts = mapOf("cam" to CamerasModel.Attempt(ConnectTarget.Nearby(camera), id)))
        assertTrue(DiscoveryRestart.WHEN_IDLE.allows(idle, live = false))
        assertFalse(DiscoveryRestart.WHEN_IDLE.allows(connecting, live = false))
        assertFalse(DiscoveryRestart.WHEN_IDLE.allows(idle, live = true))
        assertTrue(DiscoveryRestart.ANY_TIME.allows(connecting, live = true))
    }
}
