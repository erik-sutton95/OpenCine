package com.opencapture.opencine.appkit

import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorRect
import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorChromeEditBoxesTest {
    private val layout = LiveMonitorLayout.fit(400f, 800f, safeLeading = 0f, safeTrailing = 0f,
        safeTop = 44f, safeBottom = 34f, showsBottomBars = true)
    private val zoom = MonitorRect(10f, 10f, 40f, 40f)
    private val stick = MonitorRect(50f, 300f, 80f, 80f)

    @Test fun mountedSectionsInEditorOrderWithChipsAndWithoutEmptyBoxes() {
        val chips = mapOf(
            MonitorDisplaySection.FPS to MonitorRect(1f, 2f, 30f, 20f),
            MonitorDisplaySection.TIMECODE to MonitorRect(40f, 2f, 60f, 20f),
            MonitorDisplaySection.COLOR to MonitorRect(0f, 0f, 0f, 0f),
        )
        val boxes = monitorChromeEditBoxes(layout, { true }, uiLocked = false, zoom, MonitorRect(0f, 0f, 0f, 0f), chips)
        assertEquals(
            listOf(
                MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.TIMECODE, MonitorDisplaySection.FPS,
                MonitorDisplaySection.LOCK_BUTTON, MonitorDisplaySection.BATTERIES, MonitorDisplaySection.RAIL_SETTINGS,
                MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_RECORD, MonitorDisplaySection.TOOL_BAR,
                MonitorDisplaySection.CAMERA_VALUES, MonitorDisplaySection.ZOOM_CHIP,
            ),
            boxes.map { it.first },
        )
        assertEquals(layout.topDeck, boxes.first().second)
        assertEquals(zoom, boxes.last().second)
    }

    @Test fun onlyTheLockStaysWhileLockedWhenNothingMounts() {
        assertEquals(emptyList(), monitorChromeEditBoxes(layout, { false }, uiLocked = false, zoom, stick))
        assertEquals(
            listOf(MonitorDisplaySection.LOCK_BUTTON to layout.lock),
            monitorChromeEditBoxes(layout, { false }, uiLocked = true, zoom, stick),
        )
    }
}
