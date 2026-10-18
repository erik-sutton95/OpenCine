package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorOperatorPreferencesTest {
    private fun keys(prefix: String = "operator") = MonitorOperatorPreferences.Keys(
        "$prefix.awake", "$prefix.hdr", "$prefix.confirm", "$prefix.haptics", "$prefix.originals", "legacy.awake",
    )

    @Test fun absentChoicesUseDefaultsWithoutWritingAndExplicitOffSurvivesReload() {
        val memory = PreferencesMemory()
        val store = MonitorOperatorPreferences(memory.storage, keys())
        assertTrue(store.keepScreenAwake && store.recordConfirmation && store.haptics && store.cacheOriginals)
        assertFalse(store.hdrDisplay)
        assertTrue(memory.values.isEmpty())
        store.keepScreenAwake = false
        store.recordConfirmation = false
        store.haptics = false
        store.cacheOriginals = false
        store.hdrDisplay = true
        val reloaded = MonitorOperatorPreferences(memory.storage, keys())
        assertFalse(reloaded.keepScreenAwake || reloaded.recordConfirmation || reloaded.haptics || reloaded.cacheOriginals)
        assertTrue(reloaded.hdrDisplay)
        assertTrue(memory.values["operator.hdr"] == true)
    }

    @Test fun legacyAwakeIsReadWithoutRewriteAndCurrentKeyWins() {
        val memory = PreferencesMemory()
        memory.values["legacy.awake"] = false
        val store = MonitorOperatorPreferences(memory.storage, keys())
        assertFalse(store.keepScreenAwake)
        assertFalse(memory.values.containsKey("operator.awake"))
        store.keepScreenAwake = true
        assertTrue(store.keepScreenAwake)
        assertFalse(memory.values["legacy.awake"] == true)
    }

    @Test fun appStorageAndKeyNamespacesStayIndependent() {
        val firstStorage = PreferencesMemory()
        val secondStorage = PreferencesMemory()
        val first = MonitorOperatorPreferences(firstStorage.storage, keys())
        val second = MonitorOperatorPreferences(secondStorage.storage, keys())
        val third = MonitorOperatorPreferences(firstStorage.storage, keys("other"),
            MonitorOperatorPreferences.Defaults(recordConfirmation = false, haptics = false))
        first.recordConfirmation = false
        first.haptics = false
        assertTrue(second.recordConfirmation && second.haptics)
        assertFalse(third.recordConfirmation || third.haptics)
        third.haptics = true
        assertFalse(first.haptics)
        assertTrue(third.haptics)
    }

    /** Remote shutter (A2-32): on until the operator turns it off, like OpenZCine, under the app's key. */
    @Test fun remoteShutterIsOnByDefaultAndAnExplicitOffSurvivesReload() {
        val memory = PreferencesMemory()
        val withKey = keys().copy(remoteShutter = "operator.remote")
        val store = MonitorOperatorPreferences(memory.storage, withKey)
        assertTrue(store.remoteShutter)
        assertFalse(memory.values.containsKey("operator.remote"))
        var heard = 0
        store.addChangeListener { heard++ }
        store.remoteShutter = false
        assertTrue(heard == 1, "The Settings write reaches the monitor that arms the shutter")
        assertFalse(MonitorOperatorPreferences(memory.storage, withKey).remoteShutter)
        assertTrue(memory.values["operator.remote"] == false)
    }

    /** An app that offers no remote shutter names no key: it reads the default and stores nothing. */
    @Test fun anAppWithoutARemoteShutterKeyStoresNoRemoteChoice() {
        val memory = PreferencesMemory()
        val store = MonitorOperatorPreferences(memory.storage, keys(),
            MonitorOperatorPreferences.Defaults(remoteShutter = false))
        assertTrue(keys().remoteShutter == null)
        assertFalse(store.remoteShutter)
        assertTrue(memory.values.isEmpty())
    }

    /** A2-18 for generated apps: the scene root that applies screen wake hears each Settings write. */
    @Test fun aChangeListenerHearsEachWriteUntilItCloses() {
        val store = MonitorOperatorPreferences(PreferencesMemory().storage, keys())
        var heard = 0
        val listening = store.addChangeListener { heard++ }
        store.keepScreenAwake = false
        assertTrue(heard == 1 && !store.keepScreenAwake)
        listening.close()
        store.keepScreenAwake = true
        assertTrue(heard == 1, "A closed listener hears nothing")
    }
}

/** Exercises the real SharedPreferences calls without requiring a native Android test host. */
private class PreferencesMemory {
    val values = mutableMapOf<String, Boolean>()
    val storage: SharedPreferences = Proxy.newProxyInstance(
        SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java),
    ) { _, method, arguments ->
        when (method.name) {
            "contains" -> values.containsKey(arguments!![0] as String)
            "getBoolean" -> values[arguments!![0] as String] ?: arguments[1]
            "edit" -> editor()
            else -> error("Unexpected preferences call: ${method.name}")
        }
    } as SharedPreferences

    private fun editor(): SharedPreferences.Editor {
        val changes = mutableMapOf<String, Boolean>()
        return Proxy.newProxyInstance(
            SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java),
        ) { proxy, method, arguments ->
            when (method.name) {
                "putBoolean" -> { changes[arguments!![0] as String] = arguments[1] as Boolean; proxy }
                "apply" -> { values.putAll(changes); null }
                else -> error("Unexpected editor call: ${method.name}")
            }
        } as SharedPreferences.Editor
    }
}
