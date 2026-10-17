package com.opencapture.monitorui

import kotlin.math.ceil
import kotlin.math.floor

/** Complete native content stays fixed; only decorative padding yields to the occupied budget. */
data class MonitorTelemetryPadding private constructor(val width: Float, val padding: Float, val fits: Boolean) {
    constructor(contentWidth: Float, availableWidth: Float, preferredWidth: Float,
        minimumTarget: Float, scale: Float) : this(calculate(contentWidth, availableWidth, preferredWidth, minimumTarget, scale))

    private constructor(value: MonitorTelemetryPadding) : this(value.width, value.padding, value.fits)

    companion object {
        private fun calculate(contentWidth: Float, availableWidth: Float, preferredWidth: Float,
            minimumTarget: Float, requestedScale: Float, preferredPadding: Float = 6f): MonitorTelemetryPadding {
            val scale = requestedScale.takeIf { it.isFinite() && it > 0f } ?: 1f
            val content = ceil(contentWidth.coerceAtLeast(0f) * scale)
            val preferred = ceil(maxOf(minimumTarget, preferredWidth) * scale)
            val available = if (availableWidth.isFinite()) floor(availableWidth.coerceAtLeast(0f) * scale) else Float.POSITIVE_INFINITY
            val fullPadding = floor(preferredPadding * scale)
            val inset = if (available >= preferred && content + 2f * fullPadding <= preferred) fullPadding
                else minOf(fullPadding, floor((available - content) / 2f).coerceAtLeast(0f))
            val width = if (available >= preferred && content + 2f * fullPadding <= preferred) preferred
                else maxOf(ceil(minimumTarget * scale), content + 2f * inset)
            return MonitorTelemetryPadding(width / scale, inset / scale, width <= available)
        }

        /** Native measures are already integral; do not convert them through dp and ceil again. */
        internal fun pixels(contentWidth: Int, availableWidth: Int, preferredWidth: Int,
            minimumTarget: Int, preferredPadding: Int): MonitorTelemetryPixelPadding {
            val fit = calculate(contentWidth.toFloat(), availableWidth.toFloat(), preferredWidth.toFloat(),
                minimumTarget.toFloat(), 1f, preferredPadding.toFloat())
            return MonitorTelemetryPixelPadding(fit.width.toInt(), fit.padding.toInt(), fit.fits)
        }
    }
}

internal data class MonitorTelemetryPixelPadding(val width: Int, val padding: Int, val fits: Boolean)

/** Real occupied targets determine the compact row; matches Swift MonitorCompactTelemetryBudget. */
class MonitorCompactTelemetryBudget private constructor(viewportWidth: Float,
    requestedLeading: Float, requestedTrailing: Float, safeLeading: Float, safeTrailing: Float,
    storageWidth: Float, powerWidth: Float, linkWidth: Float, minimumTarget: Float, requestedScale: Float,
    minimumCorner: Float, gap: Float, minimumLinkWidth: Float) {
    constructor(layout: MonitorFieldLayout, safeLeading: Float, safeTrailing: Float,
        storageWidth: Float, powerWidth: Float, linkWidth: Float, minimumTarget: Float, requestedScale: Float,
        minimumLinkWidth: Float = 0f) :
        this(layout.viewport.width, layout.status.x, layout.viewport.width - layout.status.maxX,
            safeLeading, safeTrailing, storageWidth, powerWidth, linkWidth, minimumTarget, requestedScale, 14f, 8f, minimumLinkWidth)

    val leading: Float
    val storageWidth: Float
    val performanceX: Float
    val performanceWidth: Float
    val powerX: Float
    val wrapsPower: Boolean

    init {
        val scale = requestedScale.takeIf { it.isFinite() && it > 0f } ?: 1f
        val storage = if (storageWidth > 0f) ceil(maxOf(minimumTarget, storageWidth) * scale) / scale else 0f
        val power = ceil(powerWidth.coerceAtLeast(0f) * scale) / scale
        val storageGap = if (storage > 0f && linkWidth > 0f) gap else 0f
        val powerGap = if ((storage > 0f || linkWidth > 0f) && power > 0f) gap else 0f
        val originalLeading = maxOf(requestedLeading, safeLeading)
        val originalTrailing = maxOf(requestedTrailing, safeTrailing)
        val originalBudget = floor((viewportWidth - originalLeading - originalTrailing - storage - power - storageGap - powerGap) * scale)
        val keepsCorners = originalBudget >= ceil(linkWidth.coerceAtLeast(0f) * scale)
        leading = if (keepsCorners) originalLeading else ceil(maxOf(minimumCorner, safeLeading) * scale) / scale
        val trailing = if (keepsCorners) originalTrailing else ceil(maxOf(minimumCorner, safeTrailing) * scale) / scale
        this.storageWidth = storage
        performanceX = leading + storage + storageGap
        powerX = viewportWidth - trailing - power
        val remaining = floor((powerX - powerGap - performanceX) * scale) / scale
        val singleRowWidth = remaining.coerceAtLeast(0f)
        val requiredLink = if (linkWidth > 0f) ceil(maxOf(minimumTarget, minimumLinkWidth) * scale) / scale else 0f
        wrapsPower = power > 0f && (storage > 0f || linkWidth > 0f) && requiredLink > remaining
        performanceWidth = if (wrapsPower) (floor((viewportWidth - trailing - performanceX) * scale) / scale).coerceAtLeast(0f)
            else singleRowWidth
    }

    companion object {
        /** The same budget in the native lattice, preserving each original independently rounded term. */
        internal fun pixels(viewportWidth: Int, originalLeading: Int, originalTrailing: Int,
            safeLeading: Int, safeTrailing: Int, storageWidth: Int, powerWidth: Int, linkWidth: Int,
            minimumTarget: Int, minimumCorner: Int, gap: Int, minimumLinkWidth: Int = 0): MonitorCompactTelemetryPixels {
            val fit = MonitorCompactTelemetryBudget(viewportWidth.toFloat(), originalLeading.toFloat(),
                originalTrailing.toFloat(), safeLeading.toFloat(), safeTrailing.toFloat(), storageWidth.toFloat(),
                powerWidth.toFloat(), linkWidth.toFloat(), minimumTarget.toFloat(), 1f,
                minimumCorner.toFloat(), gap.toFloat(), minimumLinkWidth.toFloat())
            return MonitorCompactTelemetryPixels(fit.leading.toInt(), fit.storageWidth.toInt(),
                fit.performanceX.toInt(), fit.performanceWidth.toInt(), fit.powerX.toInt(), fit.wrapsPower)
        }
    }
}

internal data class MonitorCompactTelemetryPixels(val leading: Int, val storageWidth: Int,
    val performanceX: Int, val performanceWidth: Int, val powerX: Int, val wrapsPower: Boolean)
