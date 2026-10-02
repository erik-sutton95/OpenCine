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
