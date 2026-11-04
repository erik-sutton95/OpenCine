package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Floating scopes never rest on the live chrome, yet still reach each screen edge where no control
 * stands (owner hardware pass 2026-10-30, iPad Pro 11-inch: a vectorscope dragged to the right edge
 * ended under DISP and the record button). Same table as Swift `MonitorScopeChromeAvoidanceTests`.
 */
class MonitorScopeChromeAvoidanceTest {
    private class Device(val name: String, val width: Float, val height: Float, val top: Float = 0f,
        val leading: Float = 0f, val bottom: Float = 0f, val trailing: Float = 0f)

    private val devices = listOf(
        Device("iPad landscape", 1210f, 834f, top = 24f, bottom = 20f),
        Device("iPad portrait", 834f, 1210f, top = 24f, bottom = 20f),
        Device("phone landscape", 874f, 402f, leading = 62f, bottom = 21f, trailing = 62f),
        Device("phone portrait", 402f, 874f, top = 62f, bottom = 34f),
    )
    /** Waveform, vectorscope, histogram and traffic lights at their base sizes. */
    private val panels = listOf(250f to 153f, 190f to 190f, 250f to 77f, 74f to 168f)
    private val gap = 8f
    private val grip = MonitorScopePanelMath.GRIP_EXTERIOR_DP
    private val gripBottom = MonitorScopePanelMath.GRIP_BOTTOM_EXTERIOR_DP
    private val withoutRecenter = MonitorScopeChrome.ALL - MonitorScopeChrome.FOCUS_RESET

    private inner class Scene(device: Device, fill: Boolean, chrome: Set<MonitorScopeChrome> = MonitorScopeChrome.ALL) {
        val layout = MonitorLayoutPolicy.fieldMonitor(device.width, device.height, device.top, device.leading,
            device.bottom, device.trailing, fill = fill, hasDisplayCutout = device.leading > 0f)
        private val floor = if (layout.portrait) layout.system.y else device.height
        val bounds = MonitorScopeRect(device.leading + gap, device.top + gap,
            device.width - device.leading - device.trailing - 2 * gap, floor - device.top - 2 * gap)
        val obstacles = layout.scopeObstacles(chrome).map { MonitorScopeRect(it.x, it.y, it.width, it.height) }

        fun drop(point: MonitorScopePoint, w: Float, h: Float): MonitorScopePoint =
            MonitorScopePanelMath.clampWithGrip(point, MonitorScopeSize(w, h), bounds, grip, obstacles, gap)

        /** The panel's body and resize strip keep the gap from every control. */
        fun isClear(center: MonitorScopePoint, w: Float, h: Float): Boolean = obstacles.all {
            center.x + w / 2 <= it.minX - gap + 0.01f || center.x - w / 2 >= it.maxX + gap - 0.01f ||
                center.y + h / 2 + gripBottom <= it.minY - gap + 0.01f || center.y - h / 2 >= it.maxY + gap - 0.01f
        }
    }

    /**
     * Corners, the record button, DISP, Settings, Media, the timecode row, the camera values and the
     * palette: wherever a scope is dropped it ends clear of every control and inside the movement
     * bounds, in either orientation, fit or fill, on a tablet and a phone.
     */
    @Test fun droppedOnAnyControlTheScopeEndsClearOfAllChrome() {
        for (device in devices) for (fill in listOf(false, true)) {
            val scene = Scene(device, fill)
            val l = scene.layout
            val w = device.width; val h = device.height
            val drops = listOf(MonitorScopePoint(w * 10, h * 10), MonitorScopePoint(w * 10, -h * 10),
                MonitorScopePoint(-w * 10, h * 10), MonitorScopePoint(-w * 10, -h * 10),
                MonitorScopePoint(l.record.midX, l.record.midY), MonitorScopePoint(l.display.midX, l.display.midY),
                MonitorScopePoint(l.settings.midX, l.settings.midY), MonitorScopePoint(l.media.midX, l.media.midY),
                MonitorScopePoint(l.status.midX, l.status.midY), MonitorScopePoint(l.values.midX, l.values.midY),
                MonitorScopePoint(l.assists.midX, l.assists.midY))
            for ((pw, ph) in panels) for (point in drops) {
                val center = scene.drop(point, pw, ph)
                val label = "${device.name} fill $fill ${pw}x$ph at $point -> $center"
                assertTrue(scene.isClear(center, pw, ph), label)
                assertEquals(center, MonitorScopePanelMath.clampWithGrip(center, MonitorScopeSize(pw, ph), scene.bounds, grip),
                    "$label left its bounds")
            }
        }
    }

    /**
     * Dragged past the right edge where no control stands, a scope still ends flush with the movement
     * bounds: mid-height beside the picture on each device, for a camera without a recenter key. A
     * phone's rail column leaves room for the histogram there, a tablet's for the vectorscope.
     */
    @Test fun draggedToTheRightEdgeAboveTheControlsTheScopeStaysFlush() {
        for (device in devices) for (fill in listOf(false, true)) {
            val (pw, ph) = if (device.name == "phone landscape") 250f to 77f else 190f to 190f
            val scene = Scene(device, fill, withoutRecenter)
            val y = if (scene.layout.portrait) scene.layout.picture.midY else device.height / 2
            val center = scene.drop(MonitorScopePoint(device.width * 10, y), pw, ph)
            assertEquals(scene.bounds.maxX, center.x + pw / 2, 0.01f, "${device.name} fill $fill")
            assertEquals(y, center.y, 0.01f, "${device.name} fill $fill moved off its row")
        }
    }

    /** The vectorscope dragged into the iPad's bottom-right corner rests beside the record column. */
    @Test fun iPadBottomRightCornerRestsNextToTheRecordColumn() {
        val scene = Scene(devices[0], false, withoutRecenter)
        val center = scene.drop(MonitorScopePoint(12_000f, 8_000f), 190f, 190f)
        assertTrue(scene.isClear(center, 190f, 190f))
        val right = center.x + 95f
        val bottom = center.y + 95f + gripBottom
        val column = minOf(scene.layout.record.x, scene.layout.display.x)
        assertTrue(right <= column - gap + 0.01f)
        assertTrue(abs(right - (column - gap)) < 0.01f || abs(bottom - (scene.layout.values.y - gap)) < 0.01f)
    }

    /** A scope already clear of the chrome stays where the operator put it. */
    @Test fun aClearScopeKeepsItsCentre() {
        for (device in devices) {
            val scene = Scene(device, false)
            val point = MonitorScopePoint(scene.layout.picture.midX, scene.layout.picture.midY)
            assertEquals(point, scene.drop(point, 74f, 100f))
        }
    }

    /** A part the surface does not show leaves its space to the scopes. */
    @Test fun hiddenChromeFreesItsSpace() {
        val layout = MonitorLayoutPolicy.fieldMonitor(1210f, 834f, safeTop = 24f, safeBottom = 20f)
        val all = layout.scopeObstacles(MonitorScopeChrome.ALL)
        val bare = layout.scopeObstacles(MonitorScopeChrome.ALL - setOf(MonitorScopeChrome.RECORD, MonitorScopeChrome.DISPLAY))
        assertTrue(layout.record in all && layout.display in all)
        assertTrue(layout.record !in bare && layout.display !in bare)
    }
}
