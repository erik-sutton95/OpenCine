package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.settings.MonitorSettingsTab
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

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

    /** A2-32: the remote shutter and auto-rotate are separate optional capabilities (Swift twin: MonitorRemoteShutterTests). */
    @Test
    fun `each input capability is declared on its own`() {
        fun controls(shutter: MonitorSettingsRemoteShutter? = null, autoRotate: MonitorSettingsAutoRotate? = null) =
            MonitorSettingsControlsSource(false, {}, false, {}, false, {}, "SIMULATED", shutter = shutter, autoRotate = autoRotate)
        var stored = false
        val shutter = MonitorSettingsRemoteShutter(false, { stored = it }, "SIMULATED shutter", "SIMULATED caption")
        val shutterOnly = controls(shutter = shutter)
        assertSame(shutter, shutterOnly.remoteShutterRow)
        assertNull(shutterOnly.autoRotateRow, "a remote shutter needs no rotation choice")
        shutterOnly.remoteShutterRow?.setEnabled?.invoke(true)
        assertTrue(stored)
        val rotation = MonitorSettingsAutoRotate(true, {}, help = "SIMULATED help")
        val rotationOnly = controls(autoRotate = rotation)
        assertSame(rotation, rotationOnly.autoRotateRow)
        assertNull(rotationOnly.remoteShutterRow, "auto-rotate needs no remote shutter")
        assertNull(controls().remoteShutterRow)
        assertNull(controls().autoRotateRow)
        val legacy = MonitorSettingsControlsSource(false, {}, false, {}, false, {}, "SIMULATED",
            remoteShutter = true, setRemoteShutter = {}, remoteTitle = "SIMULATED legacy")
        assertEquals("SIMULATED legacy", legacy.remoteShutterRow?.title)
        assertNull(legacy.autoRotateRow)
    }

    @Test
    fun `the automatic reports help is the shared disclosure`() {
        assertEquals(MonitorSettingsCopy.automaticReports, OperatorHelpCopy("SIMULATED").RELIABILITY_REPORTS)
    }
}
