package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MultiviewArrangement
import com.opencapture.monitorui.MultiviewSafeArea
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MultiviewStageViewportTest {
    @Test fun nativeInsetsKeepTheirPhysicalOrientation() {
        for (safe in listOf(MultiviewSafeArea(0f, 59f, 21f, 0f), MultiviewSafeArea(0f, 0f, 21f, 59f))) {
            val value = MultiviewStageViewport(844f, 390f, safe, MultiviewArrangement.GRID, 0)
            assertEquals(safe, value.safeArea)
            assertTrue(value.layout.tiles.all { it.maxY <= 390f })
        }
    }

    @Test fun portraitKeepsAllInsetsAndTabletWindowControlsMoveTheSharedLayout() {
        val safe = MultiviewSafeArea(59f, 0f, 34f, 0f)
        val portrait = MultiviewStageViewport(390f, 844f, safe, MultiviewArrangement.CENTER_STAGE, 1)
        assertEquals(safe, portrait.safeArea)
        val tabletSafe = MultiviewSafeArea(24f, 0f, 20f, 0f)
        val plain = MultiviewStageViewport(1194f, 834f, tabletSafe, MultiviewArrangement.GRID, 0)
        val controls = MultiviewStageViewport(1194f, 834f, tabletSafe, MultiviewArrangement.GRID, 0, 32f)
        assertEquals(plain.layout.sessionControls.y + 32f, controls.layout.sessionControls.y)
        assertEquals(4, controls.layout.tiles.size)
        assertTrue(controls.layout.tiles.all { it.maxY <= controls.height })
    }
}
