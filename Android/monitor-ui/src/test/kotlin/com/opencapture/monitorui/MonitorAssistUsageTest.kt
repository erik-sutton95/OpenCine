package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorAssistUsageTest {
    @Test fun aLoadedScriptReservesOneQuickSlotAndKeepsOtherUsageOrder() {
        val catalog = listOf("PEAK", "FALSE", "PROMPT", "ZEBRA")
        val seed = mapOf("PEAK" to 8, "FALSE" to 6, "PROMPT" to 4, "ZEBRA" to 2)
        val ranked = MonitorAssistUsage.ranked(catalog, { it }, MonitorToolUsageState(), seed, now = 100.0,
            priorityIds = listOf("PROMPT", "PROMPT", "missing"))
        assertEquals(listOf("PROMPT", "PEAK", "FALSE", "ZEBRA"), ranked)
        assertEquals(catalog, MonitorAssistUsage.ranked(catalog, { it }, MonitorToolUsageState(), seed, now = 100.0))
    }

    @Test
    fun seedOrderBeforeAnyUse() {
        val usage = MonitorToolUsageState()
        val catalog = listOf("LUT", "PEAK", "FALSE", "ZEBRA", "WAVE")
        val seed = mapOf("PEAK" to 6, "FALSE" to 5, "ZEBRA" to 4, "LUT" to 4, "WAVE" to 3)
        assertEquals(listOf("PEAK", "FALSE", "LUT", "ZEBRA", "WAVE"), usage.ranked(catalog, seed, 0.0))
    }

    @Test
    fun recencyDecaysStaleFrequency() {
        var usage = MonitorToolUsageState()
        val t0 = 1_000_000.0
        repeat(5) { usage = usage.recording("LUT", t0) }
        usage = usage.recording("WAVE", t0 + MonitorToolUsageState.HALF_LIFE)
        assertEquals("LUT", usage.ranked(listOf("LUT", "WAVE"), now = t0 + MonitorToolUsageState.HALF_LIFE).first())
        usage = usage.recording("WAVE", t0 + 2 * MonitorToolUsageState.HALF_LIFE)
        assertEquals(
            "WAVE",
            usage.ranked(listOf("LUT", "WAVE"), now = t0 + 2 * MonitorToolUsageState.HALF_LIFE).first(),
        )
    }
}
