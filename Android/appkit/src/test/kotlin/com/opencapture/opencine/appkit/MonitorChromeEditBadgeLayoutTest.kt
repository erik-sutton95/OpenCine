package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorRect
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The editor's eye badges on measured boxes (moved from Z Android's `ChromeEditLayoutTest` when Z adopted the
 * shared surface; the boxes are the ones iOS `RunnerTests` pins on the Swift twin).
 */
class MonitorChromeEditBadgeLayoutTest {
    private val size = MonitorChromeEditBadgeLayout.BADGE_SIZE

    // Measured landscape boxes from an 852x393 phone: the four readouts nest inside the status bar, and the
    // rail and camera-value strip sit flush against the screen edges.
    private val boxes = listOf(
        MonitorDisplaySection.STATUS_BAR to MonitorRect(69f, 16f, 678f, 42f),
        MonitorDisplaySection.RAIL_SETTINGS to MonitorRect(763f, 14f, 83f, 289f),
        MonitorDisplaySection.TOOL_BAR to MonitorRect(16f, 321f, 344f, 58f),
        MonitorDisplaySection.CAMERA_VALUES to MonitorRect(368f, 321f, 466f, 58f),
        MonitorDisplaySection.LOCK_BUTTON to MonitorRect(16f, 17f, 40f, 40f),
        MonitorDisplaySection.BATTERIES to MonitorRect(8f, 63f, 41f, 35f),
        MonitorDisplaySection.REC_READOUT to MonitorRect(81f, 23f, 67f, 27f),
        MonitorDisplaySection.CODEC to MonitorRect(377f, 22f, 98f, 30f),
        MonitorDisplaySection.STORAGE to MonitorRect(485f, 22f, 132f, 30f),
        MonitorDisplaySection.FPS to MonitorRect(627f, 22f, 108f, 29f),
    )

    @Test fun badgesTakeACornerOfTheirOwnElementAndNeverStackUp() {
        val placements = MonitorChromeEditBadgeLayout.badgeFrames(boxes, 852f, 393f).toMap()
        assertEquals(boxes.size, placements.size, "every measured element must get a badge")
        placements.forEach { (section, placement) ->
            assertTrue(placement.x >= 0f && placement.y >= 0f, "$section badge ran off screen")
            assertTrue(placement.x + size <= 852f && placement.y + size <= 393f, "$section badge ran off an edge")
            val box = boxes.first { it.first == section }.second
            val centreX = placement.x + size / 2f
            val centreY = placement.y + size / 2f
            assertTrue(centreX >= box.x - size && centreX <= box.maxX + size &&
                centreY >= box.y - size && centreY <= box.maxY + size, "$section badge drifted from its element")
        }
        assertApart(placements.toList())
    }

    @Test fun portraitStatusBarAndBatteriesGetSeparateEyesInSurfaceOrder() {
        // A 411x914 dp portrait phone: the batteries sit in the status bar's top corner.
        // The live surface's order: the batteries take their corner before the status bar they sit on.
        val measured = listOf(
            MonitorDisplaySection.BATTERIES to MonitorRect(358.1f, 4.2f, 45.3f, 22.1f),
            MonitorDisplaySection.STATUS_BAR to MonitorRect(8f, 0f, 383.2f, 44.2f),
            MonitorDisplaySection.CAMERA_VALUES to MonitorRect(14.1f, 728.8f, 383.2f, 81.5f),
            MonitorDisplaySection.FOCUS_BOX to MonitorRect(100f, 382f, 90.7f, 78.9f),
        )
        val placements = MonitorChromeEditBadgeLayout.badgeFrames(measured, 411.4f, 914.3f)
        assertEquals(measured.size, placements.size)
        assertApart(placements)
    }

    @Test fun unmeasuredElementsAreSkipped() {
        val placements = MonitorChromeEditBadgeLayout.badgeFrames(listOf(
            MonitorDisplaySection.STATUS_BAR to MonitorRect(0f, 0f, 0f, 0f),
            MonitorDisplaySection.LOCK_BUTTON to MonitorRect(16f, 17f, 40f, 40f)), 852f, 393f).toMap()
        assertNull(placements[MonitorDisplaySection.STATUS_BAR])
        assertNotNull(placements[MonitorDisplaySection.LOCK_BUTTON])
    }

    /**
     * One table for both twins (Swift: `MonitorChromeEditBadgeLayoutTests.placementTable`): each case lists its
     * boxes in placement order, the badges' touch target, and the exact badge origin every placed box gets; a
     * box missing from `expected` gets no badge. Measured cases are the boxes a staged review logged.
     */
    private class Case(
        val name: String,
        val width: Float,
        val height: Float,
        val touchTarget: Float,
        val boxes: List<Pair<String, MonitorRect>>,
        val expected: List<Pair<String, Pair<Float, Float>>>,
    )

    private fun box(key: String, x: Float, y: Float, w: Float, h: Float) = key to MonitorRect(x, y, w, h)

    private val placementTable = listOf(
        // Measured: iOS 852x393 landscape (the boxes Z RunnerTests pins); iOS S4 runs portrait only.
        Case(
            "iosPhoneLandscape", 852f, 393f, 44f,
            listOf(
                box("statusBar", 69f, 16f, 678f, 42f),
                box("railSettings", 763f, 14f, 83f, 289f),
                box("toolBar", 16f, 321f, 344f, 58f),
                box("cameraValues", 368f, 321f, 466f, 58f),
                box("lockButton", 16f, 17f, 40f, 40f),
                box("batteries", 8f, 63f, 41f, 35f),
                box("recReadout", 81f, 23f, 67f, 27f),
                box("codec", 377f, 22f, 98f, 30f),
                box("storage", 485f, 22f, 132f, 30f),
                box("fps", 627f, 22f, 108f, 29f),
            ),
            listOf(
                "statusBar" to (725f to 36f),
                "railSettings" to (759f to 281f),
                "toolBar" to (338f to 317f),
                "cameraValues" to (588f to 317f),
                "lockButton" to (34f to 35f),
                "batteries" to (27f to 79f),
                "recReadout" to (126f to 28f),
                "codec" to (373f to 30f),
                "storage" to (481f to 30f),
                "fps" to (623f to 29f),
            ),
        ),
        // Synthetic: b collides on every anchor and slides out to the nearest free spot; c and inner are
        // nested in bar, whose eye leaves them none, so they get no badge.
        Case(
            "crowdedStacksOutwardAndDropsNested", 800f, 400f, 44f,
            listOf(
                box("a", 100f, 100f, 30f, 30f),
                box("b", 100f, 100f, 30f, 30f),
                box("bar", 400f, 90f, 200f, 50f),
                box("c", 420f, 100f, 30f, 30f),
                box("inner", 420f, 100f, 30f, 30f),
            ),
            listOf(
                "a" to (108f to 108f),
                "b" to (108f to 152f),
                "bar" to (396f to 118f),
            ),
        ),
        // Measured: Pocket and Insta phone landscape (identical boxes; runs pocket-s4-phone-07,
        // insta-s4-phone-04).
        Case(
            "androidPhoneLandscape", 914.286f, 411.429f, 48f,
            listOf(
                box("LOCK_BUTTON", 12.19f, 12.19f, 48f, 48f),
                box("BATTERIES", 12.19f, 72.381f, 57.905f, 68.19f),
                box("STATUS_BAR", 103.619f, 0f, 733.714f, 44.19f),
                box("TOOL_BAR", 12.19f, 297.524f, 89.143f, 110.095f),
                box("CAMERA_VALUES", 112f, 372.952f, 690.286f, 34.667f),
                box("RAIL_RECORD", 838.476f, 333.333f, 70.095f, 70.095f),
                box("RAIL_MEDIA", 849.143f, 72.381f, 48f, 48f),
                box("RAIL_SETTINGS", 849.143f, 12.19f, 48f, 48f),
                box("REC_READOUT", 670.095f, 11.81f, 53.333f, 20.571f),
                box("TIMECODE", 733.333f, 8f, 77.714f, 28.19f),
                box("FORMAT", 160.381f, 12.571f, 38.476f, 19.429f),
                box("COLOR", 222.857f, 12.571f, 13.714f, 19.429f),
                box("STORAGE", 103.619f, 12.571f, 32.762f, 19.429f),
            ),
            listOf(
                "LOCK_BUTTON" to (38.19f to 38.19f),
                "BATTERIES" to (48.095f to 118.571f),
                "STATUS_BAR" to (99.619f to 22.19f),
                "TOOL_BAR" to (79.333f to 293.524f),
                "CAMERA_VALUES" to (108f to 368.952f),
                "RAIL_RECORD" to (834.476f to 329.333f),
                "RAIL_MEDIA" to (845.143f to 98.381f),
                "RAIL_SETTINGS" to (845.143f to 38.19f),
                "REC_READOUT" to (666.095f to 16f),
                "TIMECODE" to (729.333f to 16f),
                "FORMAT" to (176.857f to 16f),
            ),
        ),
        // Measured: Pocket and Insta tablet portrait (identical boxes; runs pocket-s4-tablet-07,
        // insta-s4-tablet-04).
        Case(
            "androidTabletPortrait", 800f, 1280f, 48f,
            listOf(
                box("LOCK_BUTTON", 8f, 1198f, 48f, 48f),
                box("BATTERIES", 8f, 82f, 58f, 68f),
                box("STATUS_BAR", 8f, 0f, 772f, 52f),
                box("TOOL_BAR", 8f, 1006f, 56f, 83f),
                box("CAMERA_VALUES", 14f, 1122.5f, 772f, 37.5f),
                box("RAIL_RECORD", 358f, 1180f, 84f, 84f),
                box("RAIL_MEDIA", 684f, 1198f, 48f, 48f),
                box("RAIL_SETTINGS", 744f, 1198f, 48f, 48f),
                box("REC_READOUT", 8f, 0f, 53.5f, 20.5f),
                box("TIMECODE", 350f, 0f, 88f, 31.5f),
                box("COLOR", 732f, 0f, 48f, 48f),
                box("STORAGE", 8f, 52f, 35.5f, 22.5f),
            ),
            listOf(
                "LOCK_BUTTON" to (34f to 1194f),
                "BATTERIES" to (44f to 128f),
                "STATUS_BAR" to (758f to 30f),
                "TOOL_BAR" to (42f to 1002f),
                "CAMERA_VALUES" to (16f to 1118.5f),
                "RAIL_RECORD" to (354f to 1176f),
                "RAIL_MEDIA" to (680f to 1194f),
                "RAIL_SETTINGS" to (740f to 1194f),
                "REC_READOUT" to (39.5f to 16f),
                "TIMECODE" to (416f to 16f),
                "STORAGE" to (21.5f to 64f),
            ),
        ),
    )

    @Test fun placementTableMatchesTheSwiftTwin() {
        for (case in placementTable) {
            val placed = MonitorChromeEditBadgeLayout.badgeFrames(case.boxes, case.width, case.height, case.touchTarget)
            assertEquals(case.expected.map { it.first }, placed.map { it.first }, "${case.name}: badged boxes")
            placed.zip(case.expected).forEach { (actual, want) ->
                val (key, frame) = actual
                assertEquals(want.second.first, frame.x, .01f, "${case.name} $key x")
                assertEquals(want.second.second, frame.y, .01f, "${case.name} $key y")
                assertEquals(size to size, frame.width to frame.height, "${case.name} $key size")
            }
            assertApart(placed, maxOf(size, case.touchTarget))
        }
    }

    /** No two badges' [reach]-sized squares (the disc, or the touch target centred on it) overlap. */
    private fun <K> assertApart(placements: List<Pair<K, MonitorRect>>, reach: Float = size) {
        for (i in placements.indices) for (j in i + 1 until placements.size) {
            val (a, b) = placements[i].second to placements[j].second
            assertTrue(abs(a.x - b.x) >= reach || abs(a.y - b.y) >= reach,
                "${placements[i].first} and ${placements[j].first} badges overlap")
        }
    }
}
