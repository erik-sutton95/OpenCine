package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The landscape photo monitor: setup values ride the status row's trailing corner, exposure
 * values keep the strip, and neither clips at the smallest supported widths (hardware pass
 * 2026-10-30). Same tables as Swift `MonitorStatusCornerTests`.
 */
class MonitorStatusCornerTest {
    private data class Tile(val title: String, val natural: Float, val floor: Float, val group: MonitorCaptureReadoutGroup)

    private data class Size(
        val width: Float, val height: Float,
        val top: Float = 0f, val leading: Float = 0f, val bottom: Float = 0f, val trailing: Float = 0f,
    ) {
        fun layout(sourceAspect: Float = 16f / 9f, fill: Boolean = false, valueCount: Int? = null) =
            MonitorLayoutPolicy.fieldMonitor(width, height, safeTop = top, safeLeading = leading,
                safeBottom = bottom, safeTrailing = trailing, sourceAspect = sourceAspect, fill = fill,
                valueCount = valueCount)
    }

    private val exposure = MonitorCaptureReadoutGroup.EXPOSURE
    private val setup = MonitorCaptureReadoutGroup.SETUP

    /** The nine photo values in the Nikon order, measured widths (dp match the iOS points). */
    private val photo = listOf(
        Tile("MODE", 48f, 44f, exposure), Tile("ISO", 50f, 30f, exposure),
        Tile("SHUTTER", 58f, 58f, exposure), Tile("IRIS", 52f, 34f, exposure),
        Tile("DRIVE", 54f, 45f, setup), Tile("FOCUS", 47f, 47f, setup),
        Tile("WB", 48f, 25f, setup), Tile("METER", 55f, 45f, exposure),
        Tile("PROFILE", 54f, 54f, setup),
    )

    /** Shots remaining, image area and size, and quality with their 24 dp spacing. */
    private val leadingWidth = 186f

    /** The widest values a body reports: "Natural auto" white balance and a long creative profile. */
    private val longest = listOf(54f, 47f, 103f, 70f)

    /** iPhone SE, 13 mini, 16 Pro, 16 Pro Max, a compact Android phone and an 11 inch tablet. */
    private val landscapes = listOf(
        Size(667f, 375f), Size(812f, 375f, leading = 50f, bottom = 21f, trailing = 50f),
        Size(874f, 402f, leading = 62f, bottom = 21f, trailing = 62f),
        Size(956f, 440f, leading = 62f, bottom = 21f, trailing = 62f), Size(640f, 360f),
        Size(1194f, 834f, top = 24f, bottom = 20f),
    )

    private fun trailingInset(layout: MonitorFieldLayout) =
        MonitorLayoutPolicy.recordingReadoutTrailingInset(layout.status.maxX, layout.picture.maxX)

    private fun cornerRoom(layout: MonitorFieldLayout) =
        layout.status.width - leadingWidth - MonitorStatusCorner.LEADING_GAP - trailingInset(layout)

    @Test
    fun aLandscapePhotoRowMovesOnlyTheSetupValuesInOrder() {
        val (strip, corner) = MonitorStatusCorner.split(photo, true) { it.group }
        assertEquals(listOf("MODE", "ISO", "SHUTTER", "IRIS", "METER"), strip.map { it.title })
        assertEquals(listOf("DRIVE", "FOCUS", "WB", "PROFILE"), corner.map { it.title })
        val (kept, none) = MonitorStatusCorner.split(photo, false) { it.group }
        assertEquals(photo, kept)
        assertTrue(none.isEmpty())
    }

    /**
     * Video keeps its clock in the corner, portrait keeps every value in the strip's grid, and a
     * hidden status row or hidden values leave the strip as it is.
     */
    @Test
    fun onlyAShownLandscapePhotoRowTakesTheSetupValues() {
        assertTrue(MonitorStatusCorner.holdsSetup(photo = true, portrait = false, statusShown = true, valuesShown = true))
        assertFalse(MonitorStatusCorner.holdsSetup(photo = false, portrait = false, statusShown = true, valuesShown = true))
        assertFalse(MonitorStatusCorner.holdsSetup(photo = true, portrait = true, statusShown = true, valuesShown = true))
        assertFalse(MonitorStatusCorner.holdsSetup(photo = true, portrait = false, statusShown = false, valuesShown = true))
        assertFalse(MonitorStatusCorner.holdsSetup(photo = true, portrait = false, statusShown = true, valuesShown = false))
    }

    /**
     * At every landscape size the four setup tiles fit beside the leading readouts at their
     * natural widths, inside the status row and clear of the system buttons, and the five
     * exposure tiles fit the strip without scrolling. Nine tiles did not fit a 640 dp strip.
     */
    @Test
    fun bothRowsFitWithoutNarrowingAtEverySize() {
        val (strip, corner) = MonitorStatusCorner.split(photo, true) { it.group }
        for (size in landscapes) {
            val layout = size.layout()
            val available = cornerRoom(layout)
            val tiles = MonitorStatusCorner.widths(corner.map { it.natural }, corner.map { it.floor }, available)
            assertEquals(corner.map { it.natural }, tiles, "$size")
            val cornerWidth = MonitorStatusCorner.width(tiles)
            assertTrue(cornerWidth <= available, "$size")
            val cornerX = layout.status.maxX - trailingInset(layout) - cornerWidth
            assertTrue(cornerX >= layout.status.x + leadingWidth + MonitorStatusCorner.LEADING_GAP, "$size")
            assertTrue(layout.status.maxX <= layout.settings.x, "$size")
            val stripWidth = strip.sumOf { it.natural.toDouble() } + 16.0 * (strip.size - 1)
            assertTrue(stripWidth <= layout.values.width, "$size")
        }
        val compact = Size(640f, 360f).layout()
        val all = photo.sumOf { it.natural.toDouble() } + 16.0 * (photo.size - 1)
        assertTrue(all > compact.values.width)
    }

    /** The widest values still fit without cutting a caption: tiles narrow toward their captions. */
    @Test
    fun theWidestValuesNarrowTowardTheirCaptionsAndNeverPast() {
        val floors = listOf(45f, 47f, 25f, 54f)
        for (size in landscapes) {
            val available = cornerRoom(size.layout())
            val tiles = MonitorStatusCorner.widths(longest, floors, available)
            assertTrue(tiles.zip(floors).all { (t, f) -> t >= f - 1e-3f }, "$size")
            assertTrue(tiles.zip(longest).all { (t, n) -> t <= n + 1e-3f }, "$size")
            assertTrue(MonitorStatusCorner.width(tiles) <= available + 1e-3f, "$size")
        }
    }

    /** With no room the tiles keep their whole captions; given room they keep natural widths. */
    @Test
    fun widthsKeepCaptionsWholeAtAnyRoom() {
        val natural = listOf(80f, 40f, 60f)
        val floors = listOf(40f, 40f, 30f)
        assertEquals(floors, MonitorStatusCorner.widths(natural, floors, 10f))
        assertEquals(natural, MonitorStatusCorner.widths(natural, floors, 1_000f))
        val squeezed = MonitorStatusCorner.widths(natural, floors, 154f)
        assertTrue(abs(MonitorStatusCorner.width(squeezed) - 154f) < 1e-3f)
        assertEquals(40f, squeezed[1])
    }

    /** A camera with a gimbal keeps the recenter key and AE unlock beside the cluster. */
    @Test
    fun aGimbalCameraKeepsTheKeyBesideTheCluster() {
        for (size in resetSizes) {
            val layout = size.layout()
            assertEquals(layout.focusReset, layout.focusReset(motionCluster = true), "$size")
            assertEquals(MonitorLayoutPolicy.aeUnlock(layout.focusReset, layout.assists.maxX, layout.picture.midX,
                layout.portrait), layout.aeUnlock(motionCluster = true), "$size")
        }
    }

    /**
     * Without a cluster the recenter key takes the feed's trailing bottom corner (owner request,
     * hardware pass 2026-10-30), clear of every control around it, with AE unlock on its centre side.
     */
    @Test
    fun withoutAClusterTheKeyTakesTheFeedsTrailingBottomCorner() {
        for (fill in listOf(false, true)) for (size in resetSizes) for (aspect in listOf(3f / 2f, 16f / 9f, 1f)) {
            val layout = size.layout(sourceAspect = aspect, fill = fill, valueCount = 9)
            val key = layout.focusReset(motionCluster = false)
            val label = "$size $aspect $fill"
            assertEquals(layout.focusReset.width, key.width)
            assertEquals(layout.focusReset.height, key.height)
            assertTrue(key.x >= layout.picture.midX && key.maxX <= layout.picture.maxX, label)
            assertTrue(key.y >= layout.picture.midY && key.maxY <= layout.picture.maxY, label)
            val chrome = buildList {
                addAll(listOf(layout.values, layout.record, layout.display, layout.settings, layout.media,
                    layout.lock, layout.assists, layout.status))
                if (layout.portrait) addAll(listOf(layout.aspectToggle, layout.system))
            }.filter { it.width > 0f }
            for (rect in chrome) assertFalse(overlaps(key, rect), "$label $rect")
            val unlock = layout.aeUnlock(motionCluster = false)
            assertTrue(unlock.maxX <= key.x && unlock.y == key.y, label)
            for (rect in chrome + key) assertFalse(overlaps(unlock, rect), "$label $rect")
        }
    }

    private val resetSizes = landscapes.filter { it.width != 956f } + listOf(
        Size(375f, 667f, top = 20f), Size(402f, 874f, top = 62f, bottom = 34f),
        Size(360f, 640f, top = 24f), Size(834f, 1194f, top = 24f, bottom = 20f),
    )

    private fun overlaps(a: MonitorRect, b: MonitorRect) =
        a.x < b.maxX && b.x < a.maxX && a.y < b.maxY && b.y < a.maxY
}
