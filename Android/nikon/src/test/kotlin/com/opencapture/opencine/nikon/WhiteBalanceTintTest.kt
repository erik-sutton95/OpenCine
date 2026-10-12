package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals

class WhiteBalanceTintTest {
    @Test
    fun `label matches shared-core WhiteBalanceTint convention`() {
        assertEquals("Neutral", WhiteBalanceTint.label(0, 0))
        assertEquals("A1 · M0.25", WhiteBalanceTint.label(2, -1))
        assertEquals("B1.5 · G0.75", WhiteBalanceTint.label(-3, 3))
        assertEquals("A3", WhiteBalanceTint.label(6, 0))
        assertEquals("G1.5", WhiteBalanceTint.label(0, 6))
    }

    @Test
    fun `cells round-trip from operator labels`() {
        assertEquals(0 to 0, WhiteBalanceTint.cellsFromLabel("Neutral"))
        assertEquals(2 to -1, WhiteBalanceTint.cellsFromLabel("A1 · M0.25"))
        assertEquals(-3 to 3, WhiteBalanceTint.cellsFromLabel("B1.5 · G0.75"))
        assertEquals(2 to 2, WhiteBalanceTint.cellsFromLabel("A1 · G0.5"))
    }

    @Test
    fun `full grid is 13 by 13 unique labels`() {
        val labels = WhiteBalanceTint.allLabels()
        assertEquals(169, labels.size)
        assertEquals(169, labels.toSet().size)
        // Row-major greenMagenta outer (−6…+6), amberBlue inner (−6…+6).
        assertEquals("B3 · M1.5", labels.first())
        assertEquals("A3 · G1.5", labels.last())
    }
}
