package com.opencapture.opencine.appkit

import android.graphics.Bitmap
import android.graphics.Color
import android.media.ExifInterface
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

/**
 * REQ-MEDIA-THUMB-ORIENTATION: a portrait still's grid thumbnail drew sideways on Android because
 * `BitmapFactory` ignores EXIF. Gallery thumbnails and photo pages decode through
 * [MonitorBitmapDecoder], which must show every still the way it was framed, as ImageIO does on iOS.
 */
@RunWith(AndroidJUnit4::class)
class MonitorBitmapDecoderOrientationTest {
    private val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir, "orientation-test")

    @After fun cleanUp() {
        directory.deleteRecursively()
    }

    /** A picture as framed: red top-left quadrant, the rest blue. Portrait when the body was held vertically. */
    private class Scene(val width: Int, val height: Int) {
        fun isRed(x: Int, y: Int): Boolean = x < width / 2 && y < height / 2
    }

    private fun scene(orientation: Int): Scene = if (orientation >= 5) Scene(60, 80) else Scene(80, 60)

    /** The pixels a sensor stores for [scene] when the still records EXIF [orientation]. */
    private fun sensorPixels(scene: Scene, orientation: Int): Bitmap {
        val rotated = orientation == 6 || orientation == 8
        val width = if (rotated) scene.height else scene.width
        val height = if (rotated) scene.width else scene.height
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        for (y in 0 until height) for (x in 0 until width) {
            val (sx, sy) = when (orientation) {
                3 -> scene.width - 1 - x to scene.height - 1 - y
                6 -> scene.width - 1 - y to x
                8 -> y to scene.height - 1 - x
                else -> x to y
            }
            bitmap.setPixel(x, y, if (scene.isRed(sx, sy)) Color.RED else Color.BLUE)
        }
        return bitmap
    }

    /** A JPEG of the sensor pixels; with [orientation] recorded in EXIF unless null. */
    private fun still(scene: Scene, orientation: Int, recorded: Int?): File {
        directory.mkdirs()
        val file = File(directory, "still-$orientation-${recorded ?: "none"}.jpg")
        val out = ByteArrayOutputStream()
        sensorPixels(scene, orientation).compress(Bitmap.CompressFormat.JPEG, 95, out)
        file.writeBytes(out.toByteArray())
        if (recorded != null) {
            ExifInterface(file.path).apply {
                setAttribute(ExifInterface.TAG_ORIENTATION, recorded.toString())
                saveAttributes()
            }
        }
        return file
    }

    private fun assertShowsAsFramed(bitmap: Bitmap?, scene: Scene) {
        assertNotNull(bitmap)
        bitmap!!
        assertEquals(scene.width, bitmap.width)
        assertEquals(scene.height, bitmap.height)
        for ((qx, qy) in listOf(1 to 1, 3 to 1, 1 to 3, 3 to 3)) {
            val x = scene.width * qx / 4
            val y = scene.height * qy / 4
            val pixel = bitmap.getPixel(x, y)
            val red = Color.red(pixel) > 160 && Color.blue(pixel) < 96
            assertEquals("quadrant at $x,$y", scene.isRed(x, y), red)
        }
    }

    @Test fun stillsWithOrientation1368ShowAsFramedFromFilesAndBytes() {
        for (orientation in listOf(1, 3, 6, 8)) {
            val scene = scene(orientation)
            val file = still(scene, orientation, recorded = orientation)
            assertShowsAsFramed(MonitorBitmapDecoder.decode(file, MonitorBitmapDecoder.THUMBNAIL_EDGE), scene)
            assertShowsAsFramed(MonitorBitmapDecoder.decode(file.readBytes(), MonitorBitmapDecoder.THUMBNAIL_EDGE), scene)
        }
    }

    @Test fun anUntaggedThumbnailTakesTheOrientationLearnedFromItsStill() {
        for (orientation in listOf(3, 6, 8)) {
            val scene = scene(orientation)
            val thumbnail = still(scene, orientation, recorded = null)
            assertShowsAsFramed(
                MonitorBitmapDecoder.decode(thumbnail.readBytes(), MonitorBitmapDecoder.THUMBNAIL_EDGE, fallbackOrientation = orientation),
                scene,
            )
        }
    }

    @Test fun anOrientationTheBytesRecordWinsOverTheFallback() {
        val scene = scene(6)
        val file = still(scene, 6, recorded = 6)
        assertShowsAsFramed(MonitorBitmapDecoder.decode(file, MonitorBitmapDecoder.PAGE_EDGE, fallbackOrientation = 8), scene)
    }
}
