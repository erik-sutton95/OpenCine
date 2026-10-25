package com.opencapture.monitorui

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.cameracontrols.MonitorInstantReview
import com.opencapture.opencine.cameracontrols.MonitorInstantReviewHost
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertSame
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The instant review covers the whole monitor, the assist palette included, as on iOS. The palette
 * floats in its own popup window, which draws above the activity: a real touch on the palette's
 * key while the review is up must reach the review (and dismiss it), never the palette.
 */
@RunWith(AndroidJUnit4::class)
class MonitorInstantReviewCoverTest {
    @Test fun aPresentedReviewCoversThePaletteAndTakesItsTouches() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            val probe = Probe()
            compose(scenario, probe)
            settle()
            // Before the review: the palette floats in its own window, as it always has.
            scenario.onActivity { activity ->
                assertNotSame(activity.window.decorView, checkNotNull(probe.keyHost).rootView,
                    "Without a review the palette keeps its popup window")
            }
            scenario.onActivity { probe.presented = true }
            settle()
            scenario.onActivity { activity ->
                assertSame(activity.window.decorView, checkNotNull(probe.keyHost).rootView,
                    "Under a review the palette must render in the monitor's window, beneath the review")
            }
            val key = probe.screenKey()
            tap(key)
            settle()
            scenario.onActivity {
                assertEquals(0, probe.paletteToggles, "The covered palette must not take a touch")
                assertEquals(1, probe.dismissals, "A touch where the palette sits dismisses the review")
            }
            // The review gone, the palette floats again.
            scenario.onActivity { probe.presented = false }
            settle()
            scenario.onActivity { activity ->
                assertNotSame(activity.window.decorView, checkNotNull(probe.keyHost).rootView)
            }
        }
    }

    private class Probe {
        var presented by mutableStateOf(false)
        var keyHost: View? = null
        var key = Offset.Zero
        var keySize = IntSize.Zero
        var paletteToggles = 0
        var dismissals = 0

        fun screenKey(): Offset {
            val origin = IntArray(2)
            checkNotNull(keyHost).getLocationOnScreen(origin)
            assertTrue(keySize.width > 0 && keySize.height > 0, "The palette key must lay out")
            return key + Offset(origin[0] + keySize.width / 2f, origin[1] + keySize.height / 2f)
        }
    }

    private fun compose(scenario: ActivityScenario<MonitorTestActivity>, probe: Probe) {
        scenario.onActivity { activity ->
            activity.setContent {
                Box(Modifier.fillMaxSize()) {
                    MonitorInstantReviewHost(presented = probe.presented) {
                        Box(Modifier.align(Alignment.BottomStart).offset(16.dp, (-24).dp)) {
                            MonitorAssistPalette(
                                tools = listOf("Peaking", "False Color", "Zebra", "Waveform"),
                                portrait = true, locked = false, isOn = { false },
                                title = { it }, label = { it }, hasOptions = { false },
                                onToggle = { probe.paletteToggles++ }, onOptions = {},
                                glyph = { tool, _, modifier ->
                                    if (tool == "Peaking") {
                                        probe.keyHost = LocalView.current
                                        Box(modifier.onGloballyPositioned {
                                            probe.key = it.positionInRoot()
                                            probe.keySize = it.size
                                        }) { Text("P") }
                                    } else {
                                        Text(tool.take(1), modifier)
                                    }
                                },
                                chevron = { _, _ -> Box(Modifier.size(14.dp)) { Text(">") } },
                            )
                        }
                    }
                    if (probe.presented) {
                        MonitorInstantReview(
                            image = ImageBitmap(64, 48), isFullResolution = true,
                            onDismiss = { probe.dismissals++; probe.presented = false },
                            favorited = false, infoLine = "SIMULATED ISO 800 1/250 f/4",
                        )
                    }
                }
            }
        }
        SystemClock.sleep(500)
        instrumentation.waitForIdleSync()
    }

    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun tap(point: Offset) {
        val down = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, point.x, point.y, 0)
                .apply { source = InputDevice.SOURCE_TOUCHSCREEN }
            instrumentation.uiAutomation.injectInputEvent(event, true)
            event.recycle()
        }
    }

    private fun settle() {
        instrumentation.waitForIdleSync()
        SystemClock.sleep(64)
    }
}
