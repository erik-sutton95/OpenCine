package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The DRIVE drum's ladder, shared by every Nikon app (moved from the Z app). */
class StillDriveDrumTest {
    /**
     * The body's SET, this drum's ORDER. Same table as the shared core's
     * `theDriveDrumKeepsReleaseOrderAndDropsTheTimer`.
     */
    @Test
    fun `the drive drum keeps release order and drops the timer`() {
        // What the ZR actually enumerates: ascending raw value, which interleaves the continuous
        // modes and drops the self-timer into the middle.
        val advertised =
            listOf("Single", "Continuous H", "Continuous L", "Self-timer", "Continuous H+", "C15", "C30")

        val options = StillPickerLadders.driveDrumOptions(advertised)

        assertEquals(
            listOf("Single", "Continuous L", "Continuous H", "Continuous H+", "C15", "C30"),
            options,
        )
        assertFalse(options.contains("Self-timer"))
    }

    /** A body is never offered a mode it did not advertise: why advertised beats invented. */
    @Test
    fun `the drive drum never invents a mode the body lacks`() {
        val options = StillPickerLadders.driveDrumOptions(listOf("Single", "Continuous L"))

        assertEquals(listOf("Single", "Continuous L"), options)
        assertFalse(options.contains("C120"))
    }

    /** A position this build has never heard of stays reachable, after the ones it can order. */
    @Test
    fun `an unknown advertised drive mode is kept rather than dropped`() {
        assertEquals(
            listOf("Single", "Continuous H", "C240"),
            StillPickerLadders.driveDrumOptions(listOf("Continuous H", "Single", "C240")),
        )
    }

    /** Only excluded positions leaves nothing this drum owns. */
    @Test
    fun `a drive enum of only excluded positions is empty`() {
        assertTrue(StillPickerLadders.driveDrumOptions(listOf("Self-timer", "Quick")).isEmpty())
    }
}
