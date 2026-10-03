package com.opencapture.opencine.appkit

import android.content.SharedPreferences
import com.opencapture.monitorui.MonitorToolUsageState
import java.lang.reflect.Proxy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFails
import kotlin.test.assertNotNull
import org.json.JSONObject

class MonitorToolUsagePreferencesTest {
    @Test fun absentAndMalformedValuesAreReadWithoutWriting() {
        val memory = UsagePreferencesMemory()
        val store = MonitorToolUsagePreferences(memory.storage, "usage")
        assertEquals(MonitorToolUsageState(), store.value)
        assertFalse(memory.values.containsKey("usage"))
        memory.values["usage"] = "not JSON"
        assertEquals(MonitorToolUsageState(), store.value)
        assertEquals("not JSON", memory.values["usage"])
    }

    @Test fun legacySchemaKeepsScoresCountsTimesAndRanking() {
        val memory = UsagePreferencesMemory()
        val raw = """{"scores":{"PEAK":2.5,"future":1},"counts":{"PEAK":3,"future":1},"lastUsed":{"PEAK":100,"future":90},"clock":100}"""
        memory.values["usage"] = raw
        val value = MonitorToolUsagePreferences(memory.storage, "usage").value
        assertEquals(mapOf("PEAK" to 2.5, "future" to 1.0), value.scores)
        assertEquals(mapOf("PEAK" to 3, "future" to 1), value.counts)
        assertEquals(mapOf("PEAK" to 100.0, "future" to 90.0), value.lastUsed)
        assertEquals(100.0, value.clock)
        assertEquals(listOf("PEAK", "future"), value.ranked(listOf("future", "PEAK"), now = 100.0))
        assertEquals(raw, memory.values["usage"])
    }

    @Test fun unknownToolIDsAndExplicitEmptyUsageSurviveReload() {
        val memory = UsagePreferencesMemory()
        val store = MonitorToolUsagePreferences(memory.storage, "usage")
        val original = MonitorToolUsageState(scores = mapOf("future" to -0.5),
            counts = mapOf("future" to Int.MAX_VALUE), lastUsed = mapOf("future" to 2.0), clock = 3.0)
        store.value = original
        val reloaded = MonitorToolUsagePreferences(memory.storage, "usage")
        assertEquals(original, reloaded.value)
        val legacy = JSONObject(memory.values["usage"]!!)
        assertEquals(-0.5, legacy.getJSONObject("scores").getDouble("future"))
        assertEquals(Int.MAX_VALUE, legacy.getJSONObject("counts").getInt("future"))
        assertEquals(2.0, legacy.getJSONObject("lastUsed").getDouble("future"))
        assertEquals(3.0, legacy.getDouble("clock"))
        reloaded.value = MonitorToolUsageState()
        assertEquals(MonitorToolUsageState(), store.value)
        assertNotNull(memory.values["usage"])
    }

    @Test fun appStorageAndKeyNamespacesStayIndependent() {
        val firstStorage = UsagePreferencesMemory()
        val secondStorage = UsagePreferencesMemory()
        val first = MonitorToolUsagePreferences(firstStorage.storage, "usage")
        val second = MonitorToolUsagePreferences(secondStorage.storage, "usage")
        val third = MonitorToolUsagePreferences(firstStorage.storage, "other")
        first.value = MonitorToolUsageState(counts = mapOf("PEAK" to 2))
        third.value = MonitorToolUsageState(counts = mapOf("LUT" to 1))
        assertEquals(mapOf("PEAK" to 2), first.value.counts)
        assertEquals(MonitorToolUsageState(), second.value)
        assertEquals(mapOf("LUT" to 1), third.value.counts)
    }

    @Test fun nonFiniteWriteRetainsThePreviousStoredBytes() {
        val memory = UsagePreferencesMemory()
        val store = MonitorToolUsagePreferences(memory.storage, "usage")
        store.value = MonitorToolUsageState(counts = mapOf("PEAK" to 2))
        val before = memory.values["usage"]
        assertFails { store.value = MonitorToolUsageState(scores = mapOf("PEAK" to Double.NaN)) }
        assertEquals(before, memory.values["usage"])
        assertEquals(mapOf("PEAK" to 2), store.value.counts)
    }

    @Test fun kotlinPartialSchemaKeepsItsPerFieldFallback() {
        val memory = UsagePreferencesMemory()
        val raw = """{"scores":{"PEAK":2.5}}"""
        memory.values["usage"] = raw
        assertEquals(MonitorToolUsageState(scores = mapOf("PEAK" to 2.5)),
            MonitorToolUsagePreferences(memory.storage, "usage").value)
        assertEquals(raw, memory.values["usage"])
    }
}

/** Uses the real storage API; no Android host or changes to production storage are needed. */
private class UsagePreferencesMemory {
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
