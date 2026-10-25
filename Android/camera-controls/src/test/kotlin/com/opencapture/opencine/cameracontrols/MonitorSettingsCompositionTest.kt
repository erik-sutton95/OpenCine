package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.settings.MonitorSettingsTab
import com.opencapture.opencine.appkit.MonitorRemoteShutter
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

    @Test
    fun `published primary positional tail still binds explicit tabs assist cards and source`() {
        val requestedTabs = listOf(MonitorSettingsTab.LINK, MonitorSettingsTab.CONTROLS)
        val configured = MonitorOperatorSettingsConfiguration("App", false, "SIMULATED", {}, null, {},
            MonitorSettingsLinkSource("SIMULATED", "", "", "", "", "", null), null, null, null,
            MonitorSettingsControlsSource(false, {}, false, {}, false, {}, keepAwakeHelp = ""),
            null, null, null, MonitorSettingsSupportSource(report = {}), null, null, null,
            requestedTabs, emptyList(), null)
        assertSame(requestedTabs, configured.tabs)
        assertNull(configured.gyro)
        assertTrue(configured.assistSections.isEmpty())
        assertNull(configured.assist)
    }

    @Test
    fun `optional gyro keeps saved logs reachable even when capture is unavailable`() {
        val gyro = MonitorSettingsGyroSource(false, {}, "SIMULATED", available = false, openLogs = {})
        val configuration = MonitorOperatorSettingsConfiguration("App", false, "SIMULATED", {}, null, {},
            MonitorSettingsLinkSource("SIMULATED", "", "", "", "", "", null), null, null, null,
            MonitorSettingsControlsSource(false, {}, false, {}, false, {}, keepAwakeHelp = ""), null,
            support = MonitorSettingsSupportSource(report = {}), gyro = gyro)
        assertSame(gyro, configuration.gyro)
        assertTrue(MonitorSettingsTab.STORAGE in configuration.tabs)
        assertEquals(monitorSettingsTabs(null, null, null, gyro = gyro), configuration.tabs)
    }

    /** Gyro capture UX: the calibrate row is shown only for a host that can open calibration (Swift twin: gyroCalibrateRowAppearsOnlyWhenProvided). */
    @Test
    fun gyroCalibrateRowOnlyWhenProvided() {
        var calibrated = 0
        val withCalibrate = MonitorSettingsGyroSource(true, {}, "SIMULATED", openLogs = {}, calibrate = { calibrated += 1 })
        assertEquals(listOf(MonitorSettingsGyroRow.LOGGING, MonitorSettingsGyroRow.STATUS, MonitorSettingsGyroRow.CALIBRATE),
            monitorSettingsGyroRows(withCalibrate))
        withCalibrate.calibrate?.invoke()
        assertEquals(1, calibrated)
        val without = MonitorSettingsGyroSource(true, {}, "SIMULATED", openLogs = {})
        assertNull(without.calibrate)
        assertEquals(listOf(MonitorSettingsGyroRow.LOGGING, MonitorSettingsGyroRow.STATUS), monitorSettingsGyroRows(without))
    }

    /** The mount preset parameters stay for existing callers until a later minor release. */
    @Test
    @Suppress("DEPRECATION")
    fun deprecatedMountPresetParametersStillBind() {
        val configure = {}
        val legacy = MonitorSettingsGyroSource(true, {}, "SIMULATED", openLogs = {}, mountName = "SIMULATED mount",
            configureMount = configure)
        assertEquals("SIMULATED mount", legacy.mountName)
        assertSame(configure, legacy.configureMount)
        assertNull(legacy.calibrate)
        assertEquals(listOf(MonitorSettingsGyroRow.LOGGING, MonitorSettingsGyroRow.STATUS, MonitorSettingsGyroRow.MOUNT),
            monitorSettingsGyroRows(legacy))
        assertNull(MonitorSettingsGyroSource(true, {}, "SIMULATED", openLogs = {}).mountName)
    }

    /** A2-32: the remote shutter and auto-rotate are separate optional capabilities (Swift twin: MonitorRemoteShutterTests). */
    @Test
    fun `each input capability is declared on its own`() {
        fun controls(shutter: MonitorSettingsRemoteShutter? = null, autoRotate: MonitorSettingsAutoRotate? = null) =
            MonitorSettingsControlsSource(false, {}, false, {}, false, {}, "SIMULATED", shutter = shutter, autoRotate = autoRotate)
        var stored = false
        val shutter = MonitorSettingsRemoteShutter(false, { stored = it }, "SIMULATED shutter", "SIMULATED caption")
        val shutterOnly = controls(shutter = shutter)
        assertSame(shutter, shutterOnly.shutter)
        assertNull(shutterOnly.autoRotateRow, "a remote shutter needs no rotation choice")
        shutterOnly.shutter?.setEnabled(true)
        assertTrue(stored)
        val rotation = MonitorSettingsAutoRotate(true, {}, help = "SIMULATED help")
        val rotationOnly = controls(autoRotate = rotation)
        assertSame(rotation, rotationOnly.autoRotateRow)
        assertNull(rotationOnly.shutter, "auto-rotate needs no remote shutter")
        assertNull(controls().shutter)
        assertNull(controls().autoRotateRow)
    }

    @Test
    fun `the media-button shutter is one typed declaration with the owner's copy`() {
        var stored = false
        val shutter = MonitorSettingsRemoteShutter.mediaButtons(false) { stored = it }
        assertEquals(MonitorRemoteShutter.TITLE, shutter.title)
        assertEquals(MonitorRemoteShutter.CAPTION, shutter.caption)
        shutter.setEnabled(true)
        assertTrue(stored)
    }

    @Test
    fun `settings without a sharing domain publish no Sharing tab unless the app asks for one`() {
        fun configuration(tabs: List<MonitorSettingsTab>? = null): MonitorOperatorSettingsConfiguration {
            val link = MonitorSettingsLinkSource("Wi-Fi", "", "Live", "", "Link Health", "Live", null)
            val controls = MonitorSettingsControlsSource(false, {}, false, {}, false, {}, keepAwakeHelp = "")
            val support = MonitorSettingsSupportSource(report = {})
            return if (tabs == null) {
                MonitorOperatorSettingsConfiguration("App", true, "Live", {}, null, {}, link, null, null, null,
                    controls, null, support = support)
            } else {
                MonitorOperatorSettingsConfiguration("App", true, "Live", {}, null, {}, link, null, null, null,
                    controls, null, support = support, tabs = tabs)
            }
        }
        assertNull(configuration().gyro)
        assertEquals(monitorSettingsTabs(null, null, null), configuration().tabs)
        assertEquals(MonitorSettingsTab.entries.toList(), configuration(MonitorSettingsTab.entries.toList()).tabs)
    }

    @Test
    fun `the automatic reports help is the shared disclosure`() {
        assertEquals(MonitorSettingsCopy.automaticReports, OperatorHelpCopy("SIMULATED").RELIABILITY_REPORTS)
    }
}
