package com.opencapture.monitorui

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Swift suite `MonitorStatusGlowRenderingTests`. The live header readouts stay legible over a bright
 * picture through the shared readout glow, not an opaque bar. White readouts over a white picture
 * only show dark pixels where the glow draws them.
 */
@RunWith(AndroidJUnit4::class)
class MonitorStatusGlowRenderTest {
    @Test(timeout = 60_000) fun portraitHeaderReadoutsCarryTheDarkGlowOverABrightPicture() =
        assertGlow("portrait") { width, height -> MonitorLayoutPolicy.fieldMonitor(width, height, safeTop = 24f) }

    @Test(timeout = 60_000) fun landscapeHeaderReadoutsCarryTheDarkGlowOverABrightPicture() =
        assertGlow("landscape") { width, _ -> MonitorLayoutPolicy.fieldMonitor(width, width * .46f) }

    private fun assertGlow(name: String, field: (Float, Float) -> MonitorFieldLayout) {
        ActivityScenario.launch(MonitorBackdropRenderActivity::class.java).use { scenario ->
            var layout: MonitorFieldLayout? = null
            var density = 1f
            scenario.onActivity { activity ->
                val metrics = activity.resources.displayMetrics
                density = metrics.density
                val field = field(metrics.widthPixels / density, metrics.heightPixels / density).also { layout = it }
                activity.setContent {
                    Box(Modifier.requiredSize(field.viewport.width.dp, field.viewport.height.dp).background(Color.White)) {
                        MonitorStatusChrome(field, MonitorStatusPresentation(false, timecode = "18:37:37:02"),
                            modifier = Modifier.offset(field.status.x.dp, field.status.y.dp).width(field.status.width.dp),
                            storage = { Text("916 GB", style = MonitorTypography.readout(14f)) },
                            format = { Text("6K 25p", style = MonitorTypography.readout(if (field.portrait) 23f else 16f)) },
                            color = { Text("N-Log", style = MonitorTypography.readout(16f)) })
                    }
                }
            }
            val image = capture(scenario, name)
            val status = checkNotNull(layout).status
            val left = (status.x * density).roundToInt().coerceAtLeast(0)
            val top = ((status.y - 40f) * density).roundToInt().coerceAtLeast(0)
            val right = ((status.x + status.width) * density).roundToInt().coerceAtMost(image.width)
            val bottom = ((status.y + status.height + 40f) * density).roundToInt().coerceAtMost(image.height)
            var dark = 0
            for (y in top until bottom) for (x in left until right) {
                val pixel = image.getPixel(x, y)
                if (maxOf(android.graphics.Color.red(pixel), android.graphics.Color.green(pixel),
                        android.graphics.Color.blue(pixel)) <= 64) dark++
            }
            assertTrue(dark > 200, "$name: the header readouts lost their dark glow ($dark dark pixels)")
        }
    }

    private fun capture(scenario: ActivityScenario<MonitorBackdropRenderActivity>, name: String): Bitmap {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        Thread.sleep(160) // wait for actual display presentation, not just Compose apply
        val latch = CountDownLatch(1)
        var image: Bitmap? = null
        var status = -1
        scenario.onActivity { activity ->
            val bitmap = Bitmap.createBitmap(activity.window.decorView.width, activity.window.decorView.height, Bitmap.Config.ARGB_8888)
            image = bitmap
            // Test-only window readback verifies actual HWUI output. Production never PixelCopies chrome.
            PixelCopy.request(activity.window, bitmap, { result -> status = result; latch.countDown() }, Handler(Looper.getMainLooper()))
        }
        assertTrue(latch.await(5, TimeUnit.SECONDS), "window capture timed out")
        assertEquals(PixelCopy.SUCCESS, status)
        val bitmap = checkNotNull(image)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        File(context.getExternalFilesDir(null), "status-glow-$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        return bitmap
    }
}
