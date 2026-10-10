package com.opencapture.monitorui

import kotlin.math.round

data class MonitorScopePoint(val x: Float, val y: Float)

data class MonitorScopeSize(val width: Float, val height: Float)

data class MonitorScopeRect(val x: Float, val y: Float, val width: Float, val height: Float) {
    val minX: Float
        get() = x
    val minY: Float
        get() = y
    val maxX: Float
        get() = x + width
    val maxY: Float
        get() = y + height
    val midX: Float
        get() = x + width / 2f
    val midY: Float
        get() = y + height / 2f

    fun contains(px: Float, py: Float): Boolean = px in minX..maxX && py in minY..maxY

    /** Aspect-fit a picture of `aspect` (width/height) inside this rect. */
    fun fittedContent(aspect: Float): MonitorScopeRect {
        val ratio = if (aspect.isFinite() && aspect > 0f) aspect else 16f / 9f
        if (height <= 0f) return this
        return if (width / height > ratio) {
            val w = height * ratio
            MonitorScopeRect(x + (width - w) / 2f, y, w, height)
        } else {
            val h = width / ratio
            MonitorScopeRect(x, y + (height - h) / 2f, width, h)
        }
    }
}

data class MonitorScopeStoredCenter(val xFraction: Double, val yFraction: Double) {
    constructor(center: MonitorScopePoint, bounds: MonitorScopeRect) : this(
        ((center.x - bounds.minX) / maxOf(bounds.width, 1f)).toDouble(),
        ((center.y - bounds.minY) / maxOf(bounds.height, 1f)).toDouble(),
    )

    fun center(bounds: MonitorScopeRect): MonitorScopePoint =
        MonitorScopePoint(
            bounds.minX + xFraction.toFloat() * bounds.width,
            bounds.minY + yFraction.toFloat() * bounds.height,
        )
}

object MonitorScopePanelSize {
    val waveform = MonitorScopeSize(250f, 153f)
    val parade = MonitorScopeSize(250f, 153f)
    val histogram = MonitorScopeSize(250f, 77f)
    val vectorscope = MonitorScopeSize(190f, 190f)
    val trafficLights = MonitorScopeSize(74f, 168f)
    val ndMeter = MonitorScopeSize(84f, 30f)
    val audio = MonitorScopeSize(28f, 168f)
    val falseColorReference = MonitorScopeSize(264f, 52f)
}

object MonitorScopePanelMath {
    const val HOLD_SECONDS = 0.3
    const val POSITION_GRID = 4f
    const val SCALE_MIN = 0.6
    const val SCALE_MAX = 1.6
    /** Thumb well for the L-corner. Larger than iOS 56 so the grip is easy to hit. */
    const val GRIP_HIT_DP = 90f
    /** Native corner drawing size. */
    const val GRIP_VISUAL_DP = 14f
    /** How far the L drawing sits past the clip (iOS `gripExteriorGap`). */
    const val GRIP_EXTERIOR_GAP_DP = 2f
    /** How much of [GRIP_HIT_DP] hangs off the panel (outside the clip). */
    const val GRIP_EXTERIOR_DP = 40f
    const val GRIP_BOTTOM_EXTERIOR_DP = 12f
    const val MIN_GRIP_HIT_DP = 44f
    const val DRAG_HIT_PADDING_DP = 10f

    val gripPadDp: Float
        get() = GRIP_EXTERIOR_DP

    /** Top-leading of the hit well: [GRIP_EXTERIOR_DP] past the clip, rest on the plate. */
    fun gripHitSize(panelWidth: Float, panelHeight: Float): Float =
        maxOf(MIN_GRIP_HIT_DP, minOf(GRIP_HIT_DP, panelWidth + GRIP_EXTERIOR_DP,
            panelHeight + GRIP_BOTTOM_EXTERIOR_DP))

    fun gripHitOrigin(panelWidth: Float, panelHeight: Float): MonitorScopePoint {
        val hit = gripHitSize(panelWidth, panelHeight)
        return MonitorScopePoint(panelWidth - hit + GRIP_EXTERIOR_DP,
            panelHeight - hit + GRIP_BOTTOM_EXTERIOR_DP)
    }

    /** Extra wrapper space above/left of a small body, so Compose does not shrink the target. */
    fun gripOverhang(panelWidth: Float, panelHeight: Float): MonitorScopePoint {
        val origin = gripHitOrigin(panelWidth, panelHeight)
        return MonitorScopePoint(maxOf(0f, -origin.x), maxOf(0f, -origin.y))
    }

    /** Top-leading of the 14 dp L inside the hit well, 2 dp outside the clip. */
    fun gripVisualOrigin(hitSize: Float = GRIP_HIT_DP): MonitorScopePoint {
        val x = hitSize - GRIP_EXTERIOR_DP + GRIP_EXTERIOR_GAP_DP - GRIP_VISUAL_DP
        val y = hitSize - GRIP_BOTTOM_EXTERIOR_DP + GRIP_EXTERIOR_GAP_DP - GRIP_VISUAL_DP
        return MonitorScopePoint(x, y)
    }

    fun clampedScale(value: Double): Double = value.coerceIn(SCALE_MIN, SCALE_MAX)

    fun panelSize(base: MonitorScopeSize, scale: Double): MonitorScopeSize {
        val clamped = clampedScale(scale)
        return MonitorScopeSize(round(base.width * clamped.toFloat()), round(base.height * clamped.toFloat()))
    }

    fun clamp(point: MonitorScopePoint, size: MonitorScopeSize, bounds: MonitorScopeRect): MonitorScopePoint {
        val halfW = size.width / 2f
        val halfH = size.height / 2f
        return MonitorScopePoint(
            point.x.coerceIn(bounds.minX + halfW, maxOf(bounds.minX + halfW, bounds.maxX - halfW)),
            point.y.coerceIn(bounds.minY + halfH, maxOf(bounds.minY + halfH, bounds.maxY - halfH)),
        )
    }

    /** Pixel bounds fit the body horizontally and reserve the resize well vertically. */
    fun fittedSize(preferred: MonitorScopeSize, bounds: MonitorScopeRect, grip: Float): MonitorScopeSize {
        val bottomGrip = grip * GRIP_BOTTOM_EXTERIOR_DP / GRIP_EXTERIOR_DP
        val factor = minOf(1f, maxOf(1f, bounds.width) / maxOf(1f, preferred.width),
            maxOf(1f, bounds.height - bottomGrip) / maxOf(1f, preferred.height))
        return MonitorScopeSize(maxOf(1f, kotlin.math.floor(preferred.width * factor)),
            maxOf(1f, kotlin.math.floor(preferred.height * factor)))
    }

    fun clampWithGrip(point: MonitorScopePoint, size: MonitorScopeSize, bounds: MonitorScopeRect, grip: Float): MonitorScopePoint {
        if (grip <= 0f) return clamp(point, size, bounds)
        val density = grip / GRIP_EXTERIOR_DP
        val bottomGrip = GRIP_BOTTOM_EXTERIOR_DP * density
        val hit = gripHitSize(size.width / density, size.height / density) * density
        // Equal body margins; the visible corner fits the padding, while its expanded
        // touch well may extend beyond the side boundary or beneath fixed controls.
        val minX = bounds.minX + size.width / 2
        val minY = bounds.minY + maxOf(size.height / 2, hit - bottomGrip - size.height / 2)
        return MonitorScopePoint(point.x.coerceIn(minX, maxOf(minX, bounds.maxX - size.width / 2)),
            point.y.coerceIn(minY, maxOf(minY, bounds.maxY - size.height / 2 - bottomGrip)))
    }

    fun snap(point: MonitorScopePoint, grid: Float = POSITION_GRID): MonitorScopePoint =
        MonitorScopePoint(round(point.x / grid) * grid, round(point.y / grid) * grid)

    fun resolvedCenter(
        session: MonitorScopePoint?,
        stored: MonitorScopeStoredCenter?,
        defaultCenter: MonitorScopePoint,
        size: MonitorScopeSize,
        bounds: MonitorScopeRect,
    ): MonitorScopePoint {
        if (session != null) return clamp(session, size, bounds)
        if (stored != null) return clamp(stored.center(bounds), size, bounds)
        return clamp(defaultCenter, size, bounds)
    }
}
