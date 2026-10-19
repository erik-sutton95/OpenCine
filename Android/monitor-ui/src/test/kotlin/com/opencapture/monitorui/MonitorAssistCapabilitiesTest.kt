package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Swift twin: MonitorAssistCapabilitiesTests. */
class MonitorAssistCapabilitiesTest {
    @Test
    fun `the standard declaration keeps the shared list`() {
        val standard = MonitorAssistCapabilities.standard
        assertEquals(MonitorAssistTool.settingsCases, MonitorAssistTool.settingsCases.filter { standard.offers(it, photography = false) })
        assertTrue(standard.levelStyles.isEmpty())
        assertFalse(standard.hasLevelStyle)
        assertTrue(standard.videoOnly.isEmpty())
        assertTrue(standard.offers(MonitorAssistTool.LUT, photography = true))
    }

    @Test
    fun `a camera declares photography only tools level styles and missing sources`() {
        val camera = MonitorAssistCapabilities(setOf(MonitorAssistTool.EV),
            listOf(MonitorLevelStyle.HORIZON, MonitorLevelStyle.GAUGE), setOf(MonitorAssistTool.ND))
        assertFalse(camera.offers(MonitorAssistTool.EV, photography = false))
        assertTrue(camera.offers(MonitorAssistTool.EV, photography = true))
        assertFalse(camera.offers(MonitorAssistTool.ND, photography = true))
        assertTrue(camera.hasLevelStyle)
        assertEquals(listOf("Horizon", "Gauge"), camera.levelStyles.map { it.title })
        assertEquals(MonitorLevelStyle.GAUGE, MonitorLevelStyle.fromStoredName("GAUGE"))
        assertNull(MonitorLevelStyle.fromStoredName("Gauge"))
    }

    @Test
    fun `a video only tool leaves photography`() {
        val camera = MonitorAssistCapabilities(videoOnly = setOf(MonitorAssistTool.LUT))
        assertTrue(camera.offers(MonitorAssistTool.LUT, photography = false))
        assertFalse(camera.offers(MonitorAssistTool.LUT, photography = true))
        assertTrue(camera.offers(MonitorAssistTool.PEAK, photography = true))
    }
}
