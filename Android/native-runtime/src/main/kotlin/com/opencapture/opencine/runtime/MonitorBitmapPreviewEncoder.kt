package com.opencapture.opencine.runtime

import android.graphics.Bitmap
import java.io.ByteArrayOutputStream

/** Explicit deployment budgets; native processing has no knowledge of any relay or schema. */
public class MonitorBitmapPreviewEncoding(
    public val maximumWidth: Int,
    public val qualityPercent: Int,
    fallbackWidths: List<Int>,
    public val qualityReduction: Int,
    public val minimumQuality: Int,
    public val maximumEncodedBytes: Int,
) {
    public val fallbackWidths: List<Int> = fallbackWidths.toList()
    init {
        require(maximumWidth > 0 && qualityPercent in 0..100 && maximumEncodedBytes > 0)
        require(this.fallbackWidths.all { it > 0 } && qualityReduction >= 0 && minimumQuality in 0..100)
    }
}

/** Original bitmap ring snapshot, pixel scaling and bounded JPEG fallback producer. */
public object MonitorBitmapPreviewEncoder {
    public fun snapshot(source: Bitmap, maximumWidth: Int): Bitmap? = try {
        val scale = minOf(1f, maximumWidth.toFloat() / source.width.toFloat())
        val width = (source.width * scale).toInt().coerceAtLeast(1)
        val height = (source.height * scale).toInt().coerceAtLeast(1)
        if (width == source.width && height == source.height) {
            source.copy(source.config ?: Bitmap.Config.ARGB_8888, false)
        } else { Bitmap.createScaledBitmap(source, width, height, true) }
    } catch (_: OutOfMemoryError) { null }

    public fun encode(source: Bitmap, profile: MonitorBitmapPreviewEncoding): ByteArray? {
        val widths = (listOf(profile.maximumWidth) + profile.fallbackWidths)
            .map { minOf(source.width, it) }.distinct()
        val qualities = intArrayOf(profile.qualityPercent,
            profile.qualityPercent - profile.qualityReduction, profile.minimumQuality).distinct()
        for (width in widths) {
            val candidate = scaledCopy(source, width) ?: continue
            try {
                for (quality in qualities) {
                    val bytes = ByteArrayOutputStream().use { output ->
                        if (!candidate.compress(Bitmap.CompressFormat.JPEG, quality, output)) return@use null
                        output.toByteArray()
                    }
                    if (bytes != null && bytes.size <= profile.maximumEncodedBytes) return bytes
                }
            } finally { if (candidate !== source && !candidate.isRecycled) candidate.recycle() }
        }
        return null
    }
    private fun scaledCopy(source: Bitmap, targetWidth: Int): Bitmap? = try {
        if (source.width <= targetWidth) source else {
            val targetHeight = (source.height * targetWidth.toFloat() / source.width.toFloat()).toInt()
            Bitmap.createScaledBitmap(source, targetWidth, targetHeight.coerceAtLeast(1), true)
        }
    } catch (_: OutOfMemoryError) { null }
}
