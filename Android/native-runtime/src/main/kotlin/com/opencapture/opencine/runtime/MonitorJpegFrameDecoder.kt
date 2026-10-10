package com.opencapture.opencine.runtime

import android.graphics.Bitmap
import android.graphics.BitmapFactory

class MonitorJpegFrameDecoder(
    /**
     * Maximum long-side pixels for the decoded bitmap. `0` keeps the source
     * resolution. The host passes its source profile limit explicitly.
     */
    private val maxLongSide: Int = 0,
) {
    private val pool = arrayOfNulls<Bitmap>(3)
    private var next = 0
    private val options =
        BitmapFactory.Options().apply {
            inMutable = true
            inPreferredConfig = Bitmap.Config.ARGB_8888
            // Keep the JPEG's declared color space intact. Forcing sRGB here
            // would erase wide-gamut/HDR evidence before the fail-closed gate
            // can reject a source the monitor cubes do not yet support.
        }

    /** Decodes [jpeg] into the next pooled bitmap; null if the data is invalid. */
    fun decode(jpeg: ByteArray): Bitmap? {
        options.inSampleSize = 1
        if (maxLongSide > 0) {
            options.inJustDecodeBounds = true
            options.inBitmap = null
            BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            options.inSampleSize =
                monitorJpegSampleSizeForLongSide(options.outWidth, options.outHeight, maxLongSide)
            options.inJustDecodeBounds = false
        }
        // Prefer pool reuse; IllegalArgumentException resets the ring slot.
        options.inBitmap = pool[next]
        val decoded =
            try {
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } catch (_: IllegalArgumentException) {
                // Pooled bitmap incompatible (size/sample change), decode fresh.
                options.inBitmap = null
                BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options)
            } ?: return null
        pool[next] = decoded
        next = (next + 1) % pool.size
        return decoded
    }

}

fun monitorJpegSampleSizeForLongSide(width: Int, height: Int, maxLongSide: Int): Int {
    if (maxLongSide <= 0 || width <= 0 || height <= 0) return 1
    val longSide = maxOf(width, height)
    var sample = 1
    // Grow sample until decoded long side is at most maxLongSide.
    while (longSide / sample > maxLongSide) {
        sample *= 2
    }
    return sample
}
