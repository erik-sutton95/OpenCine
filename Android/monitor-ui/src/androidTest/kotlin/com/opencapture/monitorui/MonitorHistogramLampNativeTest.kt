package com.opencapture.monitorui

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.ScopeChannelLight
import com.opencapture.opencine.media.ScopeHistogramDisplay
import com.opencapture.opencine.media.ScopeTrafficLightsReading
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED readings through actual Android Canvas and HWUI window readback. */
@RunWith(AndroidJUnit4::class)
class MonitorHistogramLampNativeTest {
    @Test fun everyChannelLampFitsAtTheMinimumPanelScale() {
        for (height in listOf(77f, 77f * .6f)) {
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                var bounds = Rect.Zero
                val ready = CountDownLatch(1)
                val lamp = ScopeChannelLight(clip = true, crush = true, level = .5)
                scenario.onActivity { activity ->
                    activity.setContent {
                        Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black),
                            contentAlignment = Alignment.Center) {
                            MonitorHistogramScopePlot(ScopeHistogramDisplay.EMPTY,
                                ScopeTrafficLightsReading(lamp, lamp, lamp), modifier = Modifier.size(150.dp, height.dp)
                                    .onGloballyPositioned { bounds = it.boundsInWindow() })
                        }
                    }
                    val view = activity.window.decorView
                    view.postOnAnimation { view.postOnAnimation { ready.countDown() } }
                }
                assertTrue("Actual display frames must present", ready.await(5, TimeUnit.SECONDS))
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                val captured = CountDownLatch(1)
                var status = -1
                lateinit var image: Bitmap
                scenario.onActivity { activity ->
                    image = Bitmap.createBitmap(activity.window.decorView.width, activity.window.decorView.height,
                        Bitmap.Config.ARGB_8888)
                    PixelCopy.request(activity.window, image, { result -> status = result; captured.countDown() },
                        Handler(Looper.getMainLooper()))
                }
                assertTrue("Native window capture must complete", captured.await(5, TimeUnit.SECONDS))
                assertEquals(PixelCopy.SUCCESS, status)
                assertTrue("The actual plot has bounds", bounds.width > 100f && bounds.height > 40f)
                val counts = intArrayOf(0, 0, 0)
                for (y in bounds.top.roundToInt() until bounds.bottom.roundToInt()) {
                    for (x in bounds.left.roundToInt() until bounds.right.roundToInt()) {
                        val pixel = image.getPixel(x, y)
                        val r = Color.red(pixel); val g = Color.green(pixel); val b = Color.blue(pixel)
                        if (r > 180 && r > g + 100 && r > b + 100) counts[0]++
                        if (g > 180 && g > r + 70 && g > b + 70) counts[1]++
                        if (b > 180 && b > r + 70 && b > g + 70) counts[2]++
                    }
                }
                val context = InstrumentationRegistry.getInstrumentation().targetContext
                File(context.getExternalFilesDir(null), "histogram-all-lamps-$height.png").outputStream().use {
                    image.compress(Bitmap.CompressFormat.PNG, 100, it)
                }
                image.recycle()
                assertTrue("Every actual channel paints at $height: ${counts.toList()}", counts.min() > 40)
                assertTrue("No channel is cropped at $height: ${counts.toList()}", counts.min() >= counts.max() * .8)
            }
        }
    }
}
