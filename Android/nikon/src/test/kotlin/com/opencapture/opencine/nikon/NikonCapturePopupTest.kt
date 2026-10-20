package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.CaptureLock
import com.opencapture.opencine.vocabulary.CaptureTint
import com.opencapture.opencine.vocabulary.LadderWrite
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The Nikon capture popups as values: the tabs, locks, writes and steps the shared ladder sheet
 * draws, so the Z app only reads the session and routes writes. Twin of the Swift
 * NikonCapturePopupTests, case for case.
 */
class NikonCapturePopupTest {
    private fun state(kind: NikonCapturePopupKind, modes: List<NikonLadderMode>) =
        NikonCapturePopupState(kind = kind, title = "T", subtitle = "S", modes = modes)

    private fun mode(index: Int, title: String, options: List<String> = listOf("A", "B")) =
        NikonLadderMode(index = index, title = title, options = options, current = options.firstOrNull().orEmpty())

    @Test
    fun photoAutoISOLadderKeepsTheBodysOffLadderPick() {
        assertEquals(listOf("3200", "3600", "4000"), NikonCapturePopupState.including("3600", listOf("3200", "4000")))
        assertEquals(listOf("100", "25600", "51200"), NikonCapturePopupState.including("51200", listOf("100", "25600")))
        assertEquals(listOf("50", "100", "200"), NikonCapturePopupState.including("50", listOf("100", "200")))
        assertEquals(listOf("400", "800"), NikonCapturePopupState.including("800", listOf("400", "800")))
        assertEquals(listOf("800"), NikonCapturePopupState.including(null, listOf("800")))
        assertEquals(listOf("800"), NikonCapturePopupState.including("Auto", listOf("800")))
    }

    @Test
    fun autoISOLocksEachDrumAndLeavingAutoWritesTheCircuit() {
        var popup = state(NikonCapturePopupKind.ISO, listOf(mode(0, "Auto On"), mode(1, "Auto Off")))
            .copy(autoIso = true, isoCameraOwned = true, circuitIndex = 0)
        val sheet = popup.presentation
        assertNull(sheet.lock)
        assertTrue(sheet.tabs.all { it.ladder.lock == CaptureLock.AUTO })
        assertTrue(sheet.lockBanner?.startsWith("Auto ISO is on") == true)
        assertEquals(LadderWrite<NikonLadderControl>(NikonLadderControl.AutoIso, "On"), sheet.tabs[0].activate)
        assertFalse(sheet.tabs[0].applyOnActivate)
        assertEquals(LadderWrite<NikonLadderControl>(NikonLadderControl.AutoIso, "Off"), sheet.tabs[1].activate)
        assertTrue(sheet.tabs[1].applyOnActivate)

        popup = popup.copy(isoRecordingLocked = true)
        assertEquals(CaptureLock.RECORDING, popup.presentation.lock)
        assertTrue(popup.presentation.tabs.all { it.ladder.lock == null })
    }

    @Test
    fun shutterCircuitTabsWriteOnlyTheCircuitAndTheCameraLockFreezesTheSheet() {
        var popup = state(NikonCapturePopupKind.SHUTTER, listOf(mode(0, "Angle"), mode(1, "Speed"))).copy(circuitIndex = 1)
        // Display order is Speed, Angle. The Speed tab keeps the body's mode index 1.
        assertEquals(listOf("Speed", "Angle"), popup.presentation.tabs.map { it.label })
        assertEquals(listOf(NikonLadderControl.Value(1), NikonLadderControl.Value(0)), popup.presentation.tabs.map { it.key })
        assertEquals(0, popup.presentation.initialTab)
        assertEquals(LadderWrite<NikonLadderControl>(NikonLadderControl.ShutterMode, "Speed"), popup.presentation.tabs[0].activate)
        assertFalse(popup.presentation.tabs[0].applyOnActivate)
        assertEquals(1, popup.copy(circuitIndex = 0).presentation.initialTab)
        assertEquals(1, popup.copy(circuitIndex = null).presentation.initialTab)
        assertEquals(LadderWrite<NikonLadderControl>(NikonLadderControl.ShutterMode, "Angle"), popup.presentation.tabs[1].activate)
        popup = popup.copy(shutterLockedOnCamera = true)
        assertEquals(CaptureLock.CAMERA_CONTROL, popup.presentation.lock)
        assertEquals("Shutter locked on camera. Hold anywhere to unlock.", popup.presentation.lockBanner)
    }

    @Test
    fun photoISOAutoTabIsLockedAndCentresOnTheLivePick() {
        val popup = state(
            NikonCapturePopupKind.STILL_ISO,
            listOf(mode(0, "Auto", listOf("3200", "4000")), mode(1, "Manual", listOf("3200", "4000"))),
        ).copy(liveIso = 3600)
        val sheet = popup.presentation
        assertEquals(CaptureLock.AUTO, sheet.tabs[0].ladder.lock)
        assertEquals(listOf("3200", "3600", "4000"), sheet.tabs[0].ladder.values)
        assertNull(sheet.tabs[1].ladder.lock)
        assertEquals(LadderWrite<NikonLadderControl>(NikonLadderControl.StillAutoIso, "Off"), sheet.tabs[1].activate)
    }

    @Test
    fun whiteBalanceOffersKelvinStepsPresetsAndTheTintPad() {
        var popup = state(
            NikonCapturePopupKind.WHITE_BALANCE,
            listOf(mode(0, "Kelvin", emptyList()), mode(1, "Preset", listOf("Auto", "Daylight")), mode(2, "Tint", emptyList())),
        ).copy(
            whiteBalanceMode = "Daylight", codec = "H.265", tintCells = 2 to -1, tintAvailable = true,
            typed = NikonControlSetting.WHITE_BALANCE,
        )
        val sheet = popup.presentation
        // Display order is Mode (the body's presets), Kelvin, Tint; keys stay mode indices.
        assertEquals(listOf("Mode", "Kelvin", "Tint"), sheet.tabs.map { it.label })
        assertEquals(
            listOf(NikonLadderControl.Value(1), NikonLadderControl.Value(0), NikonLadderControl.Value(2)),
            sheet.tabs.map { it.key },
        )
        assertEquals(0, sheet.initialTab)
        assertEquals(WbPickerPolicy.kelvinOptions, sheet.tabs[1].ladder.values)
        assertNull(sheet.tabs[1].setting)
        val steps = sheet.tabs[1].steps?.invoke("5600K")
        assertEquals("Use minus 10 and plus 10 beside the selected value to fine-adjust", sheet.tabs[1].stepsHint)
        assertNull(sheet.tabs[0].stepsHint)
        assertEquals("−10", steps?.first?.label)
        assertEquals(true, steps?.second?.lands)
        assertTrue(sheet.tabs[1].values?.invoke("5610K")?.contains("5610K") == true)
        assertEquals(
            WbPickerPolicy.whiteBalanceOptions(listOf("Auto", "Daylight"), "H.265"),
            sheet.tabs[0].ladder.values,
        )
        assertEquals(CaptureTint(greenMagenta = -1, amberBlue = 2, range = WhiteBalanceTint.cellRange), sheet.tabs[2].tint)
        assertNull(sheet.tabs[2].activate)
        assertEquals(1, popup.copy(whiteBalanceMode = "Color temp").presentation.initialTab)
        assertEquals(1, popup.copy(whiteBalanceMode = null).presentation.initialTab)
        assertEquals(listOf("Daylight"), popup.copy(codec = "R3D NE").presentation.tabs[0].ladder.values)
        assertEquals(listOf("Auto", "Daylight"), popup.copy(codec = "R3D NE", photography = true).presentation.tabs[0].ladder.values)

        popup = popup.copy(tintAvailable = false)
        assertEquals(CaptureLock.AUTO, popup.presentation.tabs[2].ladder.lock)
    }

    @Test
    fun advertisedValuesWinOverTheAppLadderAndPlainSettingsOpenOnTheBodysValue() {
        var popup = state(
            NikonCapturePopupKind.SETTINGS,
            listOf(
                NikonLadderMode(index = 0, title = "One", options = listOf("A", "B"), current = "A"),
                NikonLadderMode(index = 1, title = "Two", options = listOf("C", "D"), current = "", advertised = listOf("D", "E")),
            ),
        ).copy(cameraValue = "E")
        val sheet = popup.presentation
        assertEquals(listOf("D", "E"), sheet.tabs[1].ladder.values)
        assertNull(sheet.tabs[1].ladder.current)
        assertEquals(1, sheet.initialTab)
        popup = popup.copy(seededTab = 0)
        assertEquals(0, popup.presentation.initialTab)
    }

    @Test
    fun independentTabsAndApertureNeverWriteOnTabChange() {
        val focus = state(NikonCapturePopupKind.INDEPENDENT_TABS, listOf(mode(0, "Mode"), mode(1, "Area"))).presentation
        assertTrue(focus.tabs.all { it.activate == null && !it.applyOnActivate })
        val iris = state(NikonCapturePopupKind.APERTURE, listOf(mode(0, "Iris", listOf("f/2.8"))))
            .copy(lensApertures = listOf("f/1.8", "f/2"))
        assertEquals(listOf("f/1.8", "f/2"), iris.presentation.tabs[0].ladder.values)
        assertTrue(iris.presentation.tabs[0].applyOnActivate)
    }

    @Test
    fun aBaseValueIsMarkedOnItsTab() {
        val popup = state(
            NikonCapturePopupKind.SETTINGS,
            listOf(NikonLadderMode(index = 0, title = "One", options = listOf("A", "B"), base = "B", current = "A")),
        )
        assertEquals(setOf("B"), popup.presentation.tabs[0].ladder.marked)
    }

    @Test
    fun codecRowsOfferTheirTwoDepthsBesideTheDrum() {
        val depths = listOf(
            CodecBitDepthOption("H.265", "8-bit", "H.265 8-bit"),
            CodecBitDepthOption("H.265", "10-bit", "H.265 10-bit"),
            CodecBitDepthOption("ProRes 422 HQ", "10-bit", "ProRes 422 HQ"),
        )
        val popup = state(NikonCapturePopupKind.CODEC, listOf(mode(0, "Codec", listOf("H.265"))))
            .copy(codecRows = listOf("H.265", "ProRes 422 HQ"), codecDepths = depths, activeCodecDepth = 10)
        val tab = popup.presentation.tabs.single()
        assertEquals(listOf("H.265", "ProRes 422 HQ"), tab.ladder.values)
        val steps = tab.steps?.invoke("H.265")
        assertEquals("H.265 8-bit", steps?.first?.value)
        assertEquals("Record H.265 at 10 bit", steps?.second?.description)
        assertEquals(true, steps?.second?.selected)
        assertNull(tab.steps?.invoke("ProRes 422 HQ"))
        // Behavior audit ZIA-145: the drum tells the screen reader what the buttons beside it do.
        assertEquals("Use the bit-depth buttons beside the codec to switch depth", tab.stepsHint)
    }
}
