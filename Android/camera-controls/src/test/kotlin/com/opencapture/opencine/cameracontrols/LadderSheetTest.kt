package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.CaptureLock
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

    private fun tab(activate: LadderWrite<String>? = null, apply: Boolean = true) = LadderTab(
        label = "ISO",
        key = "iso",
        ladder = CaptureLadder(current = "800", values = listOf("400", "800")),
        activate = activate,
        applyOnActivate = apply,
    )
}
