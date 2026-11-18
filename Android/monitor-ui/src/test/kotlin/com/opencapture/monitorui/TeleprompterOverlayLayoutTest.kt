package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class TeleprompterOverlayLayoutTest {
    @Test fun landscapeReaderKeepsCameraControlsAndAllEdgesClear() {
        val layout = MonitorLayoutPolicy.fieldMonitor(852f, 393f, 0f, 44f, 21f, 44f)
        val shown = setOf(MonitorScopeChrome.STATUS, MonitorScopeChrome.SETTINGS, MonitorScopeChrome.MEDIA,
            MonitorScopeChrome.RECORD, MonitorScopeChrome.DISPLAY, MonitorScopeChrome.VALUES, MonitorScopeChrome.TOOLS)
        val frame = TeleprompterOverlayLayout.frame(layout, 44f, 0f, 21f, 44f, shown, false)
        assertTrue(frame.x >= 44 && frame.maxX <= 808)
        assertTrue(frame.y >= 0 && frame.maxY <= 372)
        assertTrue(frame.width >= 180 && frame.height >= 100)
        assertEquals(layout.status.maxY + 8f, frame.y)
        for (obstacle in layout.scopeObstacles(shown)) {
            assertTrue(!(frame.x < obstacle.maxX && frame.maxX > obstacle.x && frame.y < obstacle.maxY && frame.maxY > obstacle.y))
        }
    }
    @Test fun portraitUsesLetterboxSpaceAndKeepsControlsClear() {
        for (fill in listOf(false, true)) {
            val layout = MonitorLayoutPolicy.fieldMonitor(393f, 852f, 59f, 0f, 34f, 0f, fill = fill)
            val shown = setOf(MonitorScopeChrome.STATUS, MonitorScopeChrome.TELEMETRY, MonitorScopeChrome.LOCK,
                MonitorScopeChrome.SETTINGS, MonitorScopeChrome.MEDIA, MonitorScopeChrome.RECORD, MonitorScopeChrome.DISPLAY,
                MonitorScopeChrome.VALUES, MonitorScopeChrome.TOOLS, MonitorScopeChrome.ASPECT_TOGGLE)
            val frame = TeleprompterOverlayLayout.frame(layout, 0f, 59f, 34f, 0f, shown, false, listOf(layout.appBadge))
            assertTrue(frame.width >= 330 && frame.height >= 380)
            if (!fill) assertTrue(frame.y < layout.picture.y && frame.maxY > layout.picture.maxY)
            expectClear(frame, layout, 0f, 59f, 34f, 0f, layout.scopeObstacles(shown) + layout.appBadge)
        }
    }

    @Test fun landscapeUsesSideMarginsWithoutTouchingRailsOrBadges() {
        for (cutoutOnRight in listOf(false, true)) {
            val leading = if (cutoutOnRight) 0f else 62f
            val trailing = if (cutoutOnRight) 62f else 0f
            val layout = MonitorLayoutPolicy.fieldMonitor(956f, 440f, 0f, leading, 21f, trailing)
            val shown = setOf(MonitorScopeChrome.STATUS, MonitorScopeChrome.TELEMETRY, MonitorScopeChrome.LOCK,
                MonitorScopeChrome.SETTINGS, MonitorScopeChrome.MEDIA, MonitorScopeChrome.RECORD, MonitorScopeChrome.DISPLAY,
                MonitorScopeChrome.VALUES, MonitorScopeChrome.TOOLS)
            val frame = TeleprompterOverlayLayout.frame(layout, leading, 0f, 21f, trailing, shown, false, listOf(layout.appBadge))
            assertTrue(frame.width > 700 && frame.width * frame.height > 190_000)
            expectClear(frame, layout, leading, 0f, 21f, trailing, layout.scopeObstacles(shown) + layout.appBadge)
        }
    }

    @Test fun motionAndNativeAccessoriesKeepTheirTouchTargets() {
        val layout = MonitorLayoutPolicy.fieldMonitor(852f, 393f, 0f, 59f, 21f, 0f)
        val shown = setOf(MonitorScopeChrome.STATUS, MonitorScopeChrome.TELEMETRY, MonitorScopeChrome.LOCK,
            MonitorScopeChrome.SETTINGS, MonitorScopeChrome.MEDIA, MonitorScopeChrome.RECORD, MonitorScopeChrome.DISPLAY,
            MonitorScopeChrome.VALUES, MonitorScopeChrome.TOOLS, MonitorScopeChrome.MOTION, MonitorScopeChrome.FOCUS_RESET)
        val extra = listOf(layout.aeUnlock(true), MonitorRect(400f, 240f, 44f, 44f))
        val frame = TeleprompterOverlayLayout.frame(layout, 59f, 0f, 21f, 0f, shown, true, extra)
        assertTrue(frame.width >= 300 && frame.height >= 140)
        expectClear(frame, layout, 59f, 0f, 21f, 0f, layout.scopeObstacles(shown, true) + extra)
    }

    private fun expectClear(frame: MonitorRect, layout: MonitorFieldLayout, leading: Float, top: Float,
        bottom: Float, trailing: Float, obstacles: List<MonitorRect>) {
        assertTrue(frame.x >= leading && frame.maxX <= layout.viewport.width - trailing)
        assertTrue(frame.y >= top && frame.maxY <= layout.viewport.height - bottom)
        for (obstacle in obstacles) assertTrue(!(frame.x < obstacle.maxX + 8 && frame.maxX > obstacle.x - 8 &&
            frame.y < obstacle.maxY + 8 && frame.maxY > obstacle.y - 8))
    }

}
