package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MonitorScopePanelPlacementTest {
    @Test fun fixedPanelHasNoInvisibleResizeWell() {
        val bounds = MonitorScopeRect(0f, 0f, 100f, 100f)
        val size = MonitorScopePanelMath.fittedSize(MonitorScopeSize(100f, 100f), bounds, 0f)
        assertEquals(MonitorScopeSize(100f, 100f), size)
        assertEquals(MonitorScopePoint(50f, 50f),
            MonitorScopePanelMath.clampWithGrip(MonitorScopePoint(1000f, 1000f), size, bounds, 0f))
    }
    @Test
    fun allPanelBodiesAndVerticalResizeWellsStayInsideControlsAcrossSizesAndDensities() {
        val bases = listOf(MonitorScopePanelSize.waveform, MonitorScopePanelSize.parade, MonitorScopePanelSize.histogram,
            MonitorScopePanelSize.vectorscope, MonitorScopePanelSize.trafficLights, MonitorScopePanelSize.ndMeter)
        for ((width, height) in listOf(402f to 874f, 874f to 402f, 667f to 375f)) {
            for (density in listOf(1f, 2.75f, 3f)) {
                val safe = MonitorScopeRect(78f * density, 104f * density,
                    (width - 186f) * density, (height - 222f) * density)
                val grip = MonitorScopePanelMath.gripPadDp * density
                for (base in bases) for (scale in listOf(0.6, 1.0, 1.6)) {
                    val preferred = MonitorScopePanelMath.panelSize(base, scale)
                    val size = MonitorScopePanelMath.fittedSize(
                        MonitorScopeSize(preferred.width * density, preferred.height * density), safe, grip)
                    for (point in listOf(MonitorScopePoint(-500f, -500f), MonitorScopePoint(9000f, 9000f))) {
                        val center = MonitorScopePanelMath.clampWithGrip(point, size, safe, grip)
                        val hit = MonitorScopePanelMath.gripHitSize(size.width / density, size.height / density) * density
                        val origin = MonitorScopePanelMath.gripHitOrigin(size.width / density, size.height / density)
                        val gripLeft = center.x - size.width / 2 + origin.x * density
                        val gripTop = center.y - size.height / 2 + origin.y * density
                        assertTrue(gripLeft >= safe.minX - 0.001f && gripTop >= safe.minY - 0.001f)
                        assertTrue(gripTop + hit <= safe.maxY + 0.001f)
                        assertTrue(center.x - size.width / 2 >= safe.minX - 0.001f)
                        assertTrue(center.y - size.height / 2 >= safe.minY - 0.001f)
                        assertTrue(center.x + size.width / 2 <= safe.maxX + 0.001f)
                        assertTrue(center.y + size.height / 2 + MonitorScopePanelMath.GRIP_BOTTOM_EXTERIOR_DP * density <= safe.maxY + 0.001f)
                    }
                }
            }
        }
    }

    @Test
    fun rotationClampsSavedCornerAndLeavesPersistenceInCanvasCoordinates() {
        val canvas = MonitorScopeRect(0f, 0f, 874f, 402f)
        val stored = MonitorScopeStoredCenter(MonitorScopePoint(870f, 400f), canvas)
        val rotated = MonitorScopeRect(0f, 0f, 402f, 874f)
        val safe = MonitorScopeRect(78f, 108f, 216f, 598f)
        val size = MonitorScopePanelMath.fittedSize(MonitorScopePanelSize.waveform, safe, 40f)
        val restored = stored.center(rotated)
        val fitted = MonitorScopePanelMath.clampWithGrip(restored, size, safe, 40f)
        assertTrue(fitted.x < restored.x && fitted.y < restored.y)
        assertEquals(870f, stored.center(canvas).x, 0.001f)
        assertEquals(400f, stored.center(canvas).y, 0.001f)
    }

    @Test
    fun bottomEdgeOpensAndOnlyMainRailLimitsRightPlacement() {
        for (density in listOf(1f, 2.75f, 3f)) {
            val right = 800f
            val safe = MonitorScopeRect(8f * density, 8f * density,
                (right - 16f) * density, 386f * density)
            val size = MonitorScopeSize(250f * density, 153f * density)
            val center = MonitorScopePanelMath.clampWithGrip(MonitorScopePoint(9000f, 9000f), size, safe,
                MonitorScopePanelMath.GRIP_EXTERIOR_DP * density)
            assertEquals(382f * density, center.y + size.height / 2, 0.001f)
            assertEquals(792f * density, center.x + size.width / 2, 0.001f)
            assertTrue(center.x + size.width / 2 + 2f * density < 800f * density)
        }
    }

    @Test
    fun portraitPanelHasEqualLeftAndRightEdgeSpacing() {
        for (density in listOf(1f, 2.75f, 3f)) {
            val safe = MonitorScopeRect(8f * density, 70f * density, 386f * density, 676f * density)
            val grip = MonitorScopePanelMath.GRIP_EXTERIOR_DP * density
            for (base in listOf(MonitorScopePanelSize.parade, MonitorScopePanelSize.trafficLights, MonitorScopePanelSize.ndMeter)) {
                for (scale in listOf(0.6, 1.0, 1.6)) {
                    val preferred = MonitorScopePanelMath.panelSize(base, scale)
                    val size = MonitorScopePanelMath.fittedSize(
                        MonitorScopeSize(preferred.width * density, preferred.height * density), safe, grip)
                    val right = MonitorScopePanelMath.clampWithGrip(MonitorScopePoint(9000f, 400f * density),
                        size, safe, grip)
                    val left = MonitorScopePanelMath.clampWithGrip(MonitorScopePoint(-9000f, 400f * density),
                        size, safe, grip)
                    assertEquals(394f * density, right.x + size.width / 2, 0.001f)
                    assertEquals(8f * density, left.x - size.width / 2, 0.001f)
                    assertEquals(402f * density - right.x - size.width / 2,
                        left.x - size.width / 2, 0.001f)
                }
            }
        }
    }

    @Test
    fun smallestNdWrapperKeepsTheWholeResizeTargetWithoutMovingTheBody() {
        val size = MonitorScopePanelMath.panelSize(MonitorScopePanelSize.ndMeter, 0.6)
        val hit = MonitorScopePanelMath.gripHitSize(size.width, size.height)
        val overhang = MonitorScopePanelMath.gripOverhang(size.width, size.height)
        val origin = MonitorScopePanelMath.gripHitOrigin(size.width, size.height)
        assertEquals(44f, hit)
        assertEquals(14f, overhang.y)
        val wrapperHeight = size.height + MonitorScopePanelMath.GRIP_BOTTOM_EXTERIOR_DP + overhang.y
        assertEquals(44f, wrapperHeight)
        assertEquals(0f, origin.y + overhang.y)
        assertTrue(origin.y + overhang.y + hit <= wrapperHeight)
        val bodyTop = 100f
        val wrapperTop = bodyTop - overhang.y
        assertEquals(bodyTop, wrapperTop + overhang.y)
    }

    @Test
    fun oversizedLegacySizeDoesNotThrowDuringDefaultPlacement() {
        val point = MonitorScopePanelMath.clamp(MonitorScopePoint(0f, 0f), MonitorScopeSize(400f, 300f),
            MonitorScopeRect(0f, 0f, 100f, 50f))
        assertTrue(point.x.isFinite() && point.y.isFinite())
    }
}
