package com.opencapture.opencine.appkit

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File

/** The one bounded still decoder for gallery thumbnails and photo pages: power-of-two sampling keeps
 * the longest edge within a limit, and a decode that cannot fit in memory yields no picture. */
public object MonitorBitmapDecoder {
    public const val THUMBNAIL_EDGE: Int = 640
    public const val LIST_THUMBNAIL_EDGE: Int = 480
    public const val PAGE_EDGE: Int = 2_048

    /** Largest power-of-two sample that keeps both edges at or under [maxEdge]. */
    public fun sampleSize(width: Int, height: Int, maxEdge: Int): Int {
        if (width <= 0 || height <= 0 || maxEdge <= 0) return 1
        var sample = 1
        while (maxOf(width, height) / sample > maxEdge) sample *= 2
        return sample
    }
    public fun decode(file: File, maxEdge: Int): Bitmap? = bounded(maxEdge) { BitmapFactory.decodeFile(file.path, it) }
    public fun decode(bytes: ByteArray, maxEdge: Int): Bitmap? =
        bounded(maxEdge) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, it) }

    private inline fun bounded(maxEdge: Int, decode: (BitmapFactory.Options) -> Bitmap?): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        decode(bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) null
        else decode(BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxEdge) })
    } catch (_: OutOfMemoryError) { null } catch (_: RuntimeException) { null }
}
