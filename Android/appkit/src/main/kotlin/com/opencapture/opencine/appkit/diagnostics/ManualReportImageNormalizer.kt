package com.opencapture.opencine.appkit.diagnostics

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import com.opencapture.opencine.appkit.MonitorBitmapDecoder
import java.io.ByteArrayOutputStream

/**
 * Downsamples and re-encodes picker images off the UI thread. Output is JPEG
 * pixels only: no EXIF, GPS, or source filename.
 */
public object ManualReportImageNormalizer {
    public sealed class Result {
        public data class Ok(public val jpeg: ByteArray) : Result()
        public data object Unreadable : Result()
        public data object TooLarge : Result()
    }

    public fun prepare(context: Context, uri: Uri): Result {
        val type = context.contentResolver.getType(uri)
        if (type != null && !type.startsWith("image/")) return Result.Unreadable
        val bytes =
            runCatching {
                context.contentResolver.openInputStream(uri)?.use { ManualReportImages.readSource(it) }
            }.getOrNull() ?: return Result.Unreadable
        return prepare(bytes)
    }

    public fun prepare(bytes: ByteArray): Result {
        if (bytes.isEmpty()) return Result.Unreadable
        if (bytes.size > ManualReportImages.SOURCE_MAX_BYTES) return Result.TooLarge
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return Result.Unreadable
        val options =
            BitmapFactory.Options().apply {
                inSampleSize =
                    ManualReportImages.sampleSize(bounds.outWidth, bounds.outHeight)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return Result.Unreadable
        var oriented = applyOrientation(decoded, bytes)
        if (oriented !== decoded) decoded.recycle()
        val max = ManualReportImages.MAX_DIMENSION
        if (oriented.width > max || oriented.height > max) {
            val scale = max.toFloat() / maxOf(oriented.width, oriented.height).toFloat()
            val w = (oriented.width * scale).toInt().coerceAtLeast(1)
            val h = (oriented.height * scale).toInt().coerceAtLeast(1)
            val scaled = Bitmap.createScaledBitmap(oriented, w, h, true)
            if (scaled !== oriented) oriented.recycle()
            oriented = scaled
        }
        try {
            encode(oriented)?.let { jpeg ->
                return if (ManualReportImages.accept(listOf(jpeg)) != null) Result.Ok(jpeg)
                else Result.TooLarge
            }
            val shrink =
                Bitmap.createScaledBitmap(
                    oriented,
                    (oriented.width * 0.7f).toInt().coerceAtLeast(1),
                    (oriented.height * 0.7f).toInt().coerceAtLeast(1),
                    true,
                )
            if (shrink !== oriented) oriented.recycle()
            oriented = shrink
            val retry = encode(oriented)
            return if (retry != null && ManualReportImages.accept(listOf(retry)) != null) Result.Ok(retry)
            else Result.TooLarge
        } finally {
            if (!oriented.isRecycled) oriented.recycle()
        }
    }

    private fun encode(bitmap: Bitmap): ByteArray? {
        for (quality in intArrayOf(80, 60, 40)) {
            val out = ByteArrayOutputStream()
            if (bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out) &&
                out.size() <= ManualReportImages.MAX_EACH_BYTES
            ) {
                return out.toByteArray()
            }
        }
        return null
    }

    private fun applyOrientation(bitmap: Bitmap, jpegBytes: ByteArray): Bitmap =
        MonitorBitmapDecoder.upright(bitmap, MonitorBitmapDecoder.exifOrientation(jpegBytes))
}
