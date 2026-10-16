package com.opencapture.monitorui

import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorSideRailPlanTest {
    @Test fun everyPreferenceAndSafetyCombinationPreservesVisibility() {
        for (bits in 0 until 256) {
            fun bit(index: Int) = bits and (1 shl index) != 0
            val plan = MonitorSideRailPlan.resolve(bit(0), bit(1), bit(2), bit(3),
                bit(4), bit(5), bit(6), bit(7))
            assertEquals(bit(0) || bit(6), plan.lock)
            assertEquals(bit(1), plan.batteries)
            assertTrue(plan.disp)
            assertEquals(bit(2) || bit(7), plan.record)
            assertEquals(bit(3), plan.media)
            assertEquals(bit(4) || !bit(5), plan.settings)
            assertFalse(plan.isEmpty)
        }
    }
}
