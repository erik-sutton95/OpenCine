package com.opencapture.opencine.appkit

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.File

/** The one bounded still decoder for gallery thumbnails and photo pages: power-of-two sampling keeps
 * the longest edge within a limit, a decode that cannot fit in memory yields no picture, and the
 * picture comes out upright. `BitmapFactory` ignores EXIF, so the decoder applies the orientation the
 * bytes record, the way the Swift twin `MediaCellImageLoader` (ImageIO with the EXIF transform) does. */
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

    /** [file] decoded upright: by the EXIF orientation it records, else by [fallbackOrientation]
     * (1 to 8, learned elsewhere) when the file states none. */
    public fun decode(file: File, maxEdge: Int, fallbackOrientation: Int? = null): Bitmap? =
        bounded(maxEdge) { BitmapFactory.decodeFile(file.path, it) }
            ?.let { decodedUpright(it, exifOrientation(file) ?: fallbackOrientation) }

    /** [bytes] decoded upright: by the EXIF orientation they record, else by [fallbackOrientation]. */
    public fun decode(bytes: ByteArray, maxEdge: Int, fallbackOrientation: Int? = null): Bitmap? =
        bounded(maxEdge) { BitmapFactory.decodeByteArray(bytes, 0, bytes.size, it) }
            ?.let { decodedUpright(it, exifOrientation(bytes) ?: fallbackOrientation) }

    /** The EXIF orientation (1 to 8) [bytes] record; null when they state none or cannot be read. */
    public fun exifOrientation(bytes: ByteArray): Int? = orientation { ExifInterface(ByteArrayInputStream(bytes)) }

    /** The EXIF orientation (1 to 8) [file] records; null when it states none or cannot be read. */
    public fun exifOrientation(file: File): Int? = orientation { ExifInterface(file.path) }

    /** [bitmap] turned upright for EXIF [orientation]; the same bitmap when it is upright or unknown,
     * or when the turned copy does not fit in memory. */
    public fun upright(bitmap: Bitmap, orientation: Int?): Bitmap {
        val transform = uprightTransform(orientation) ?: return bitmap
        val matrix = Matrix()
        matrix.postRotate(transform.rotationDegrees.toFloat())
        if (transform.mirrored) matrix.postScale(-1f, 1f)
        return try {
            Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
        } catch (_: OutOfMemoryError) { bitmap } catch (_: RuntimeException) { bitmap }
    }

    /** A fresh decode turned upright; the sideways decode is released at once. */
    private fun decodedUpright(bitmap: Bitmap, orientation: Int?): Bitmap =
        upright(bitmap, orientation).also { if (it !== bitmap) bitmap.recycle() }

    /** Clockwise rotation, then a horizontal mirror, that shows a picture stored with EXIF
     * [orientation] upright (TIFF 6.0 tag 0x0112); null for upright and unknown values. */
    internal fun uprightTransform(orientation: Int?): UprightTransform? = when (orientation) {
        2 -> UprightTransform(rotationDegrees = 0, mirrored = true)
        3 -> UprightTransform(rotationDegrees = 180, mirrored = false)
        4 -> UprightTransform(rotationDegrees = 180, mirrored = true)
        5 -> UprightTransform(rotationDegrees = 90, mirrored = true)
        6 -> UprightTransform(rotationDegrees = 90, mirrored = false)
        7 -> UprightTransform(rotationDegrees = 270, mirrored = true)
        8 -> UprightTransform(rotationDegrees = 270, mirrored = false)
        else -> null
    }

    private inline fun orientation(read: () -> ExifInterface): Int? = try {
        read().getAttributeInt(ExifInterface.TAG_ORIENTATION, 0).takeIf { it in 1..8 }
    } catch (_: java.io.IOException) { null } catch (_: RuntimeException) { null }

    private inline fun bounded(maxEdge: Int, decode: (BitmapFactory.Options) -> Bitmap?): Bitmap? = try {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        decode(bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) null
        else decode(BitmapFactory.Options().apply { inSampleSize = sampleSize(bounds.outWidth, bounds.outHeight, maxEdge) })
    } catch (_: OutOfMemoryError) { null } catch (_: RuntimeException) { null }
}

/** Clockwise rotation in degrees plus a trailing horizontal mirror. */
internal data class UprightTransform(val rotationDegrees: Int, val mirrored: Boolean)
