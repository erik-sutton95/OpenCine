package com.opencapture.monitorui

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionOnScreen
import androidx.compose.ui.unit.IntSize
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.cameracontrols.LiveFeedGestureWell
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MonitorReferenceSplitInputTest {
    @Test fun dragWinsOverFocusAndOverOutsideTapDismissal() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var split by mutableFloatStateOf(.25f)
        var inspectorOpen by mutableStateOf(false)
        var focusTaps = 0
        var origin = Offset.Zero
        var size = IntSize.Zero
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    BoxWithConstraints(Modifier.fillMaxSize().onGloballyPositioned {
                        origin = it.positionOnScreen()
                        size = it.size
                    }) {
                        LiveFeedGestureWell(enabled = true, onTap = { focusTaps++ },
                            onSwipeClean = {}, onPinch = {}, onPinchEnd = {})
                        val handle: @Composable BoxScope.() -> Unit = {
                            MonitorReferenceSplitHandle(split, { split = it }, { Rect(Offset.Zero, it) },
                                Modifier.fillMaxSize())
                        }
                        if (inspectorOpen) {
                            CompositionLocalProvider(LocalMonitorInspectorBackgroundControls provides handle) {
                                // Keep the left half of the test viewport exposed beside the inspector.
                                MonitorInspector("Reference", maxWidth.value * .5f, maxHeight.value,
                                    onDismiss = { inspectorOpen = false }, trailing = true, hasNavigation = false) {}
                            }
                        } else handle(this)
                    }
                }
            }
            instrumentation.waitForIdleSync()
            fun touch(from: Float, to: Float) {
                val down = SystemClock.uptimeMillis()
                fun send(action: Int, fraction: Float) {
                    val point = origin + Offset(size.width * fraction, size.height * .5f)
                    val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, point.x, point.y, 0)
                    event.source = InputDevice.SOURCE_TOUCHSCREEN
                    try {
                        assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true))
                    } finally {
                        event.recycle()
                    }
                }
                send(MotionEvent.ACTION_DOWN, from)
                if (from != to) repeat(8) { index ->
                    send(MotionEvent.ACTION_MOVE, from + (to - from) * (index + 1) / 8)
                }
                send(MotionEvent.ACTION_UP, to)
                instrumentation.waitForIdleSync()
            }

            touch(.25f, .42f)
            scenario.onActivity { assertTrue(split > .37f, "split after drag was $split") }
            touch(.08f, .08f)
            scenario.onActivity {
                assertEquals(1, focusTaps)
                inspectorOpen = true
                split = .25f
            }
            instrumentation.waitForIdleSync()
            touch(.25f, .42f)
            scenario.onActivity {
                assertTrue(split > .37f, "split beside inspector was $split")
                assertTrue(inspectorOpen)
            }
            touch(.08f, .08f)
            scenario.onActivity {
                assertFalse(inspectorOpen)
                assertEquals(1, focusTaps)
            }
        }
    }
}
