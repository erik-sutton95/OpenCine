package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorFramingGeometryTest {
    @Test
    fun rectForRatioLetterboxesAndPillarboxes() {
        val feed = MonitorScopeRect(10f, 20f, 1920f, 1080f)
        val wide = MonitorGuideGeometry.rectForRatio(feed, 2.39f)
        assertEquals(1920f, wide.width, 0.02f)
        assertEquals(1920f / 2.39f, wide.height, 0.02f)
        assertEquals(feed.midX, wide.midX, 0.02f)
        assertEquals(feed.midY, wide.midY, 0.02f)

        val tallFeed = MonitorScopeRect(0f, 0f, 1920f, 1080f)
        val tall = MonitorGuideGeometry.rectForRatio(tallFeed, 9f / 16f)
        assertEquals(1080f, tall.height, 0.02f)
        assertEquals(1080f * 9f / 16f, tall.width, 0.02f)
        assertEquals(tallFeed.midX, tall.midX, 0.02f)
    }

    @Test
    fun sixteenNineGuideStaysInsideOneOnePicture() {
        val well = MonitorScopeRect(0f, 0f, 1920f, 1080f)
        val picture = well.fittedContent(1f)
        val frame = MonitorGuideGeometry.rectForRatio(picture, 16f / 9f)
        assertEquals(picture.width, frame.width, 0.02f)
        assertTrue(frame.maxX < well.maxX - 1f)
        assertTrue(frame.minX > well.minX + 1f)
        assertEquals(picture.midX, frame.midX, 0.02f)
    }

    @Test
    fun gridThirdsPhiAndDiagonalMatchOpenZcine() {
        assertEquals(1f / 3f, MonitorGridGeometry.thirdsFractions[0], 1e-6f)
        assertEquals(2f / 3f, MonitorGridGeometry.thirdsFractions[1], 1e-6f)
        assertEquals(0.382f, MonitorGridGeometry.phiFractions[0], 1e-6f)
        assertEquals(0.618f, MonitorGridGeometry.phiFractions[1], 1e-6f)
        assertEquals(0.22f, MonitorGridGeometry.STROKE_OPACITY, 0.0001f)

        val feed = MonitorScopeRect(10f, 20f, 900f, 600f)
        val thirds = MonitorGridGeometry.segments(feed, thirds = true, phi = false, diagonal = false)
        assertEquals(4, thirds.size)
        assertEquals(310f, thirds[0].from.x, 0.01f)
        assertEquals(20f, thirds[0].from.y, 0.01f)
        assertEquals(310f, thirds[0].to.x, 0.01f)
        assertEquals(620f, thirds[0].to.y, 0.01f)

        val phi = MonitorGridGeometry.segments(MonitorScopeRect(0f, 0f, 1000f, 1000f), thirds = false, phi = true, diagonal = false)
        assertEquals(4, phi.size)
        assertEquals(382f, phi[0].from.x, 0.01f)
        assertEquals(618f, phi[2].from.x, 0.01f)

        val diag = MonitorGridGeometry.segments(MonitorScopeRect(0f, 0f, 100f, 50f), thirds = false, phi = false, diagonal = true)
        assertEquals(MonitorScopePoint(0f, 0f), diag[0].from)
        assertEquals(MonitorScopePoint(100f, 50f), diag[0].to)
        assertEquals(MonitorScopePoint(100f, 0f), diag[1].from)
        assertEquals(MonitorScopePoint(0f, 50f), diag[1].to)

        assertTrue(
            MonitorGridGeometry.segments(MonitorScopeRect(0f, 0f, 100f, 100f), thirds = false, phi = false, diagonal = false).isEmpty(),
        )
    }

    /** Swift mirror: `MonitorGuideSafeAreasTests`. */
    @Test
    fun safeAreasDefaultOffAtNinetyAndEightyPercent() {
        val standard = MonitorGuideSafeAreas.STANDARD
        assertFalse(standard.isOn(MonitorGuideSafeAreaKind.ACTION) || standard.isOn(MonitorGuideSafeAreaKind.TITLE))
        assertEquals(90, standard.percent(MonitorGuideSafeAreaKind.ACTION))
        assertEquals(80, standard.percent(MonitorGuideSafeAreaKind.TITLE))
        assertTrue(standard.drawn.isEmpty())
        assertEquals(listOf("Action safe", "Title safe"), MonitorGuideSafeAreaKind.entries.map { it.title })
    }

    @Test
    fun eachSafeAreaSwitchesAndAdjustsOnItsOwnWithinTheRange() {
        var areas = MonitorGuideSafeAreas.STANDARD.withOn(MonitorGuideSafeAreaKind.ACTION, true)
        assertEquals(listOf(MonitorGuideSafeAreaKind.ACTION), areas.drawn.map { it.kind })
        areas = areas.withOn(MonitorGuideSafeAreaKind.TITLE, true).withPercent(MonitorGuideSafeAreaKind.ACTION, 85)
        assertEquals(listOf(MonitorGuideSafeAreaKind.ACTION, MonitorGuideSafeAreaKind.TITLE), areas.drawn.map { it.kind })
        assertEquals(listOf(85, 80), areas.drawn.map { it.percent })
        areas = areas.withPercent(MonitorGuideSafeAreaKind.TITLE, 10)
        assertEquals(50, areas.percent(MonitorGuideSafeAreaKind.TITLE))
        areas = areas.withPercent(MonitorGuideSafeAreaKind.ACTION, 140)
        assertEquals(99, areas.percent(MonitorGuideSafeAreaKind.ACTION))
        areas = areas.withOn(MonitorGuideSafeAreaKind.ACTION, false)
        assertEquals(listOf(MonitorGuideSafeAreaKind.TITLE), areas.drawn.map { it.kind })
        assertEquals(99, areas.percent(MonitorGuideSafeAreaKind.ACTION))
        assertEquals("85%", MonitorGuideSafeAreas.label(85))
    }

    @Test
    fun aSafeAreaIsTheCentredShareOfTheFrameWidthAndHeight() {
        val frame = MonitorScopeRect(10f, 20f, 1000f, 418f)
        val action = MonitorGuideSafeAreas.inset(frame, 90)
        assertEquals(900f, action.width, 0.01f)
        assertEquals(376.2f, action.height, 0.01f)
        assertEquals(frame.midX, action.midX, 0.01f)
        assertEquals(frame.midY, action.midY, 0.01f)
        assertEquals(60f, action.minX, 0.01f)
        assertEquals(990f, MonitorGuideSafeAreas.inset(frame, 120).width, 0.01f)
    }
}
