package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.json.JSONObject

class MonitorDisplayPreferencesTest {
    private val identifiers = listOf(
        "statusBar", "toolBar", "cameraValues", "lockButton", "batteries", "railRecord",
        "railMedia", "railSettings", "zoomChip", "gimbalStick", "focusBox", "recReadout",
        "timecode", "format", "codec", "color", "storage", "fps",
    )
    private val legacyIdentifiers = identifiers - "codec"
    private val keys = MonitorDisplayPreferences.Keys("legacy.live", "legacy.clean")

    @Test fun legacySectionOrderAndLiveCleanDefaultsStayStable() {
        assertEquals(identifiers, MonitorDisplaySection.entries.map { it.key })
        assertEquals(listOf("LIVE", "CLEAN", "COMMAND"), MonitorDisplayMode.entries.map { it.name })
        assertEquals(listOf("DISP 1 · Live", "DISP 2 · Clean", "DISP 3 · Command"),
            MonitorDisplayMode.entries.map { it.settingsTitle })
        assertEquals("Face Box", MonitorDisplaySection.FOCUS_BOX.title)
        for (mode in listOf(MonitorDisplayMode.LIVE, MonitorDisplayMode.CLEAN)) {
            assertEquals(MonitorDisplaySection.entries, MonitorDisplayChrome.configurableSections(mode))
        }
        assertEquals(listOf("lockButton", "batteries", "railRecord", "railMedia", "railSettings"),
            MonitorDisplayChrome.configurableSections(MonitorDisplayMode.COMMAND).map { it.key })
        assertTrue(MonitorDisplaySection.entries.all(MonitorDisplayChrome.liveDefaults::isVisible))
        assertEquals(listOf("statusBar", "toolBar", "cameraValues", "lockButton"),
            MonitorDisplaySection.entries.filter { !MonitorDisplayChrome.cleanDefaults.isVisible(it) }.map { it.key })
    }

    @Test fun chromeEncodingKeepsEveryKeyAndFalseValues() {
        val encoded = MonitorDisplayChrome.cleanDefaults.toJson()
        val obj = JSONObject(encoded)
        assertEquals(identifiers.toSet(), obj.keys().asSequence().toSet())
        assertFalse(obj.getBoolean("statusBar"))
        assertTrue(obj.getBoolean("focusBox"))
        assertEquals(MonitorDisplayChrome.cleanDefaults,
            MonitorDisplayChrome.fromJson(encoded, MonitorDisplayChrome.liveDefaults))
    }

    /** A layout saved before the codec chip existed keeps every choice and shows the chip. */
    @Test fun layoutSavedBeforeTheCodecSectionStillDecodes() {
        val memory = DisplayPreferencesMemory()
        memory.values[keys.clean] = JSONObject(legacyIdentifiers.associateWith { true }).put("statusBar", false).toString()
        val decoded = MonitorDisplayPreferences(memory.storage, keys).clean
        assertTrue(!decoded.statusBar && decoded.codec && decoded.focusBox && decoded.lockButton)
    }

    @Test fun absentLayoutsReadWithoutWritingAndExplicitOffSurvivesReload() {
        val memory = DisplayPreferencesMemory()
        val store = MonitorDisplayPreferences(memory.storage, keys)
        assertEquals(MonitorDisplayChrome.liveDefaults, store.live)
        assertEquals(MonitorDisplayChrome.cleanDefaults, store.clean)
        assertEquals(MonitorDisplayChrome.liveDefaults, store.command)
        assertTrue(memory.values.isEmpty())
        store.live = store.live.toggling(MonitorDisplaySection.STATUS_BAR)
        assertEquals(MonitorDisplayChrome.cleanDefaults, store.clean)
        store.clean = store.clean.toggling(MonitorDisplaySection.STATUS_BAR)
        val reloaded = MonitorDisplayPreferences(memory.storage, keys)
        assertFalse(reloaded.live.statusBar)
        assertTrue(reloaded.clean.statusBar)
        assertEquals(setOf(keys.live, keys.clean), memory.values.keys)
    }

    @Test fun incompleteChromeRetainsExistingPlatformFallbackWithoutRewriting() {
        val memory = DisplayPreferencesMemory()
        val incomplete = "{\"statusBar\":true}"
        val malformed = "invalid JSON"
        memory.values[keys.clean] = incomplete
        memory.values[keys.live] = malformed
        val store = MonitorDisplayPreferences(memory.storage, keys)
        // Existing Android JSON preserves supplied fields; Apple rejects a missing Codable field.
        assertEquals(MonitorDisplayChrome.cleanDefaults.copy(statusBar = true), store.clean)
        assertEquals(MonitorDisplayChrome.liveDefaults, store.live)
        assertEquals(incomplete, memory.values[keys.clean])
        assertEquals(malformed, memory.values[keys.live])
    }

    @Test fun appStorageAndKeyNamespacesStayIndependent() {
        val firstMemory = DisplayPreferencesMemory()
        val secondMemory = DisplayPreferencesMemory()
        val first = MonitorDisplayPreferences(firstMemory.storage, keys)
        val second = MonitorDisplayPreferences(secondMemory.storage, keys)
        val third = MonitorDisplayPreferences(firstMemory.storage,
            MonitorDisplayPreferences.Keys("other.live", "other.clean"))
        first.live = MonitorDisplayChrome.cleanDefaults
        third.clean = MonitorDisplayChrome.liveDefaults
        assertEquals(MonitorDisplayChrome.cleanDefaults, first.live)
        assertEquals(MonitorDisplayChrome.cleanDefaults, first.clean)
        assertEquals(MonitorDisplayChrome.liveDefaults, second.live)
        assertEquals(MonitorDisplayChrome.cleanDefaults, second.clean)
        assertEquals(MonitorDisplayChrome.liveDefaults, third.live)
        assertEquals(MonitorDisplayChrome.liveDefaults, third.clean)
    }
}

/** Real SharedPreferences calls with isolated string storage, no native test host. */
internal class DisplayPreferencesMemory {
    val values = mutableMapOf<String, String>()
    val storage: SharedPreferences = Proxy.newProxyInstance(
        SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java),
    ) { _, method, arguments ->
        when (method.name) {
            "getString" -> values[arguments!![0] as String] ?: arguments[1]
            "edit" -> editor()
            else -> error("Unexpected preferences call: ${method.name}")
        }
    } as SharedPreferences

    private fun editor(): SharedPreferences.Editor {
        val changes = mutableMapOf<String, String>()
        return Proxy.newProxyInstance(
            SharedPreferences.Editor::class.java.classLoader, arrayOf(SharedPreferences.Editor::class.java),
        ) { proxy, method, arguments ->
            when (method.name) {
                "putString" -> { changes[arguments!![0] as String] = arguments[1] as String; proxy }
                "apply" -> { values.putAll(changes); null }
                else -> error("Unexpected editor call: ${method.name}")
            }
        } as SharedPreferences.Editor
    }
}
