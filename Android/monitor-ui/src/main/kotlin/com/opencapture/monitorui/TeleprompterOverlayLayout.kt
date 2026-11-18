package com.opencapture.monitorui

/** Uses the free monitor canvas without changing picture geometry or covering camera chrome. */
public object TeleprompterOverlayLayout {
    /** Finds the largest unobstructed rectangle between status and camera values, including letterbox space. */
    public fun frame(layout: MonitorFieldLayout, safeLeading: Float, safeTop: Float,
        safeBottom: Float, safeTrailing: Float, shown: Set<MonitorScopeChrome>, motionCluster: Boolean,
        extraObstacles: List<MonitorRect> = emptyList()): MonitorRect {
        val gap = 8f
        val left = maxOf(0f, safeLeading) + 12f
        val right = layout.viewport.width - maxOf(0f, safeTrailing) - 12f
        val top = maxOf(maxOf(0f, safeTop) + 12f, if (MonitorScopeChrome.STATUS in shown) layout.status.maxY + gap else 0f)
        val bottom = minOf(layout.viewport.height - maxOf(0f, safeBottom) - 12f,
            if (MonitorScopeChrome.VALUES in shown) layout.values.y - gap else layout.viewport.height)
        if (right <= left || bottom <= top) return MonitorRect(0f, 0f, 0f, 0f)
        val obstacles = (layout.scopeObstacles(shown, motionCluster) + extraObstacles)
            .filter { it.width > 0 && it.height > 0 && it.maxX + gap > left && it.x - gap < right &&
                it.maxY + gap > top && it.y - gap < bottom }.sortedBy { it.x }
        val tops = (listOf(top) + obstacles.map { it.maxY + gap }.filter { it > top && it < bottom }).distinct().sorted()
        val bottoms = (listOf(bottom) + obstacles.map { it.y - gap }.filter { it > top && it < bottom }).distinct().sorted()
        val centerX = (left + right) / 2
        val centerY = (top + bottom) / 2
        var best = MonitorRect(0f, 0f, 0f, 0f)
        var bestDistance = Float.POSITIVE_INFINITY
        fun consider(x: Float, end: Float, y: Float, floor: Float) {
            if (end <= x) return
            val candidate = MonitorRect(x, y, end - x, floor - y)
            val dx = candidate.midX - centerX
            val dy = candidate.midY - centerY
            val distance = dx * dx + dy * dy
            val area = candidate.width * candidate.height
            if (area > best.width * best.height || (area == best.width * best.height && distance < bestDistance)) {
                best = candidate
                bestDistance = distance
            }
        }
        // Empty rectangles end at canvas or obstacle edges; scan bands and their free x intervals.
        for (y in tops) for (floor in bottoms) if (floor > y) {
            var start = left
            for (obstacle in obstacles) if (obstacle.y - gap < floor && obstacle.maxY + gap > y) {
                consider(start, minOf(right, obstacle.x - gap), y, floor)
                start = maxOf(start, obstacle.maxX + gap)
            }
            consider(start, right, y, floor)
        }
        return best
    }
}
