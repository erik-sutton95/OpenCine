package com.opencapture.monitorui

import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.view.PixelCopy
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeLevelAxis
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED empty samples isolate references in actual shared waveform/parade Canvas output. */
@RunWith(AndroidJUnit4::class)
class MonitorUnknownSignalRenderingTest {
    @Test fun rawWaveformAndParadeOmitSavedCalibratedGuides() {
        for (parade in listOf(false, true)) {
            val bounds = arrayOfNulls<Rect>(4)
            val drawn = CountDownLatch(1)
            ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    activity.setContent {
                        Column {
                            for (row in 0..1) Row {
                                for (column in 0..1) {
                                    val index = row * 2 + column
                                    val axis = if (row == 0) ScopeLevelAxis.rawCodes else ScopeLevelAxis.of(MonitorTransfer.DLOG2)
                                    val guides = if (column == 0) MonitorScopeGuides() else MonitorScopeGuides(false, false, false)
                                    Box(Modifier.size(160.dp, 90.dp).background(Color.Black).onGloballyPositioned {
                                        val rect = it.boundsInWindow()
                                        bounds[index] = Rect(rect.left.roundToInt(), rect.top.roundToInt(), rect.right.roundToInt(), rect.bottom.roundToInt())
                                        if (bounds.all { it != null }) activity.window.decorView.postOnAnimation {
                                            activity.window.decorView.postOnAnimation { drawn.countDown() }
                                        }
                                    }) {
                                        if (parade) MonitorParadeScopePlot(ScopeAssistBundle(), axis, guides = guides)
                                        else MonitorWaveformScopePlot(ScopeAssistBundle(), axis, guides = guides)
                                    }
                                }
                            }
                        }
                    }
                }
                assertTrue(drawn.await(5, TimeUnit.SECONDS), "shared plots did not reach display")
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                val copied = CountDownLatch(1)
                var image: Bitmap? = null
                var status = -1
                scenario.onActivity { activity ->
                    val bitmap = Bitmap.createBitmap(activity.window.decorView.width, activity.window.decorView.height, Bitmap.Config.ARGB_8888)
                    image = bitmap
                    PixelCopy.request(activity.window, bitmap, { status = it; copied.countDown() }, Handler(Looper.getMainLooper()))
                }
                assertTrue(copied.await(5, TimeUnit.SECONDS), "shared plot readback timed out")
                assertEquals(PixelCopy.SUCCESS, status)
                val bitmap = checkNotNull(image)
                fun pixels(index: Int): IntArray {
                    val rect = checkNotNull(bounds[index])
                    return IntArray(rect.width() * rect.height()).also {
                        bitmap.getPixels(it, 0, rect.width(), rect.left, rect.top, rect.width(), rect.height())
                    }
                }
                assertContentEquals(pixels(0), pixels(1), "raw source must omit saved calibrated guides")
                assertFalse(pixels(2).contentEquals(pixels(3)), "legacy calibrated source keeps its guides")
                bitmap.recycle()
            }
        }
    }
}
