package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.CaptureLock
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderStep
import com.opencapture.opencine.vocabulary.LadderTab
import com.opencapture.opencine.vocabulary.LadderWrite
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LadderSheetTest {
    @Test
    fun recordingAndCameraControlFreezeTheWholeSheet() {
        for (lock in listOf(CaptureLock.RECORDING, CaptureLock.CAMERA_CONTROL)) {
            val gates = ladderGates(lock, null, enabled = true)
            assertFalse(gates.tabsEnabled, lock.name)
            assertFalse(gates.drumEnabled, lock.name)
            assertTrue(gates.showBanner, lock.name)
        }
    }

    @Test
    fun autoAndExposureProgramFreezeOnlyTheDrum() {
        for (lock in listOf(CaptureLock.AUTO, CaptureLock.EXPOSURE_PROGRAM)) {
            val gates = ladderGates(null, lock, enabled = true)
            assertTrue(gates.tabsEnabled, lock.name)
            assertFalse(gates.drumEnabled, lock.name)
            assertTrue(gates.showBanner, lock.name)
        }
    }

    @Test
    fun aDisconnectedSheetStaysClosedEvenWithNoLock() {
        val gates = ladderGates(null, null, enabled = false)
        assertFalse(gates.tabsEnabled)
        assertFalse(gates.drumEnabled)
        assertFalse(gates.showBanner)
    }

    @Test
    fun activationWritesTheCircuitThenTheLandedValue() {
        val tab = tab(activate = LadderWrite("base", "Low"), apply = true)
        assertEquals(
            listOf(LadderWrite("base", "Low"), LadderWrite("iso", "800")),
            ladderActivationWrites(tab, "800"),
        )
    }

    @Test
    fun activationCanSkipTheLandedValue() {
        val tab = tab(activate = LadderWrite("mode", "Angle"), apply = false)
        assertEquals(listOf(LadderWrite("mode", "Angle")), ladderActivationWrites(tab, "180"))
    }

    @Test
    fun aBlankLandedValueIsNotWritten() {
        assertEquals(emptyList(), ladderActivationWrites(tab(apply = true), ""))
    }

    @Test
    fun aGrownLadderReplacesTheCameraList() {
        val tab = tab().copy(values = { landed -> listOf("5560K", landed) })
        assertEquals(listOf("5560K", "5600K"), ladderOptions(tab, "5600K"))
        assertEquals(listOf("400", "800"), ladderOptions(tab().copy(values = null), "800"))
    }

    @Test
    fun aStepCanRefuseToLandOnTheDrum() {
        val depth = LadderStep("10-bit", "H.265 10-bit", "Record H.265 at 10-bit", selected = true, lands = false)
        val kelvin = LadderStep("\u221210", "5550K", "Decrease Kelvin by 10", lands = true)
        assertFalse(depth.lands)
        assertNull(LadderStep("+10", null, "Increase Kelvin by 10").value)
        assertTrue(kelvin.lands)
        assertEquals("5550K", kelvin.value)
    }

    @Test
    fun theSheetStartsFreshForANewPickerTabSetOrCircuit() {
        // A3-19: positional state must not survive a different presentation.
        fun sheet(vararg keys: String, initial: Int = 0) = LadderSheetPresentation(
            title = "SHUTTER",
            subtitle = "",
            tabs = keys.map { tab().copy(key = it) },
            initialTab = initial,
        )
        val angle = sheet("angle", "speed")
        val echoed = angle.copy(tabs = angle.tabs.map { it.copy(ladder = it.ladder.copy(current = "400")) })

        assertEquals(ladderIdentity(angle), ladderIdentity(echoed))
        assertTrue(ladderIdentity(angle) != ladderIdentity(sheet("angle", "speed", initial = 1)))
        assertTrue(ladderIdentity(angle) != ladderIdentity(sheet("kelvin", "preset")))
        assertTrue(ladderIdentity(angle) != ladderIdentity(sheet("angle")))
    }

    @Test
    fun anUnknownCurrentStillWritesTheFirstPick() {
        // A3-29: nothing is applied while the camera has not reported a value.
        val unknown = tab().copy(ladder = CaptureLadder(current = null, values = listOf("400", "800")))
        val applied = unknown.ladder.current.orEmpty()

        assertEquals(LadderWrite("iso", "400"), ladderPickWrite(unknown, applied, "400"))
        assertNull(ladderPickWrite(unknown, "400", "400"))
        assertNull(ladderPickWrite(tab(), "800", "800"))
    }

    @Test
    fun aFormatPickWritesOnlyALadderValueWhileTheDrumIsOpen() {
        assertEquals(LadderWrite("iso", "400"), ladderFormatWrite(tab(), "400", enabled = true))
        assertNull(ladderFormatWrite(tab(), "1600", enabled = true))
        assertNull(ladderFormatWrite(tab(), "400", enabled = false))
    }

    private fun tab(activate: LadderWrite<String>? = null, apply: Boolean = true) = LadderTab(
        label = "ISO",
        key = "iso",
        ladder = CaptureLadder(current = "800", values = listOf("400", "800")),
        activate = activate,
        applyOnActivate = apply,
    )
}
