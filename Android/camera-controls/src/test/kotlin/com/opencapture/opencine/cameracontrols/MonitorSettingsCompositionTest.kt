package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.settings.MonitorSettingsTab
import kotlin.test.Test
import kotlin.test.assertEquals

/** A2-35: a tab whose whole optional domain is absent is left out, in one stable order (Swift twin: MonitorSettingsCompositionTests). */
class MonitorSettingsCompositionTest {
    @Test
    fun `absent sharing and storage domains leave their tabs out in the stable order`() {
        assertEquals(listOf(MonitorSettingsTab.LINK, MonitorSettingsTab.ASSIST, MonitorSettingsTab.CONTROLS,
            MonitorSettingsTab.DISPLAY, MonitorSettingsTab.SYSTEM), monitorSettingsTabs(null, null, null))
    }

    @Test
    fun `an account the app names but cannot configure keeps the Storage tab`() {
        val account = MonitorSettingsReadoutSource("Frame.io", "SIMULATED", "Not configured")
        assertEquals(listOf(MonitorSettingsTab.LINK, MonitorSettingsTab.ASSIST, MonitorSettingsTab.CONTROLS,
            MonitorSettingsTab.DISPLAY, MonitorSettingsTab.STORAGE, MonitorSettingsTab.SYSTEM),
            monitorSettingsTabs(null, null, null, account))
    }

    @Test
    fun `the automatic reports help is the shared disclosure`() {
        assertEquals(MonitorSettingsCopy.automaticReports, OperatorHelpCopy("SIMULATED").RELIABILITY_REPORTS)
    }
}
