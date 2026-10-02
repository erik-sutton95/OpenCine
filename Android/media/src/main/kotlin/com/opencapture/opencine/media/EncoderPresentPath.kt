package com.opencapture.opencine.media

/**
 * OpenPocketViewCore `EncoderPresentPath`: Pocket screen flip / vertical mode
 * restarts the encoder with new VPS/SPS/PPS. When to ask the camera to re-enable
 * live view after a change is integration policy and stays in the app.
 */
object EncoderPresentPath {
    fun parameterSetsChanged(
        hadFormat: Boolean,
        previousCsd: ByteArray?,
        nextCsd: ByteArray?,
    ): Boolean {
        if (!hadFormat) return false
        if (previousCsd == null || nextCsd == null) return previousCsd != null || nextCsd != null
        return !previousCsd.contentEquals(nextCsd)
    }

    fun feedAspect(width: Int, height: Int, fallback: Double = 16.0 / 9.0): Double {
        if (width <= 1 || height <= 1) return fallback
        return width.toDouble() / height.toDouble()
    }

    fun isVertical(width: Int, height: Int): Boolean = width > 1 && height > 1 && height > width

    fun shouldRebuildDecoderAfterParameterChange(
        pictureSizeChanged: Boolean,
        @Suppress("UNUSED_PARAMETER") accessUnitHasIDR: Boolean,
    ): Boolean = pictureSizeChanged

    fun shouldBeginIDRHoldAfterParameterChange(
        pictureSizeChanged: Boolean,
        accessUnitHasIDR: Boolean,
    ): Boolean {
        if (accessUnitHasIDR) return false
        return pictureSizeChanged
    }
}
