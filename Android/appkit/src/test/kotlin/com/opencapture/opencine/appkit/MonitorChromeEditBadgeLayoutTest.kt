package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorRect
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

    private fun assertApart(placements: List<Pair<MonitorDisplaySection, MonitorRect>>) {
        for (i in placements.indices) for (j in i + 1 until placements.size) {
            val (a, b) = placements[i].second to placements[j].second
            assertTrue(a.x + size <= b.x || b.x + size <= a.x || a.y + size <= b.y || b.y + size <= a.y,
                "${placements[i].first} and ${placements[j].first} badges overlap")
        }
    }
}
