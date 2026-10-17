package com.opencapture.monitorui

import android.graphics.Rect as AndroidRect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Real native pointers must pass a disabled raised control to the retained picker backdrop. */
@RunWith(AndroidJUnit4::class)
class MonitorChromeInputTest {
    @Test fun disabledTapChromeReturnsNativePointerToPickerBackdrop() = disabledChrome(hold = false)

    @Test fun disabledHoldChromeReturnsNativePointerToPickerBackdrop() = disabledChrome(hold = true)

    private fun disabledChrome(hold: Boolean) {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            var enabled by mutableStateOf(true)
            var presented by mutableStateOf(true)
            var bounds = Rect.Zero
            var taps = 0
            var holds = 0
            var dismissals = 0
            scenario.onActivity { activity ->
                activity.setContent {
                    Box(Modifier.fillMaxSize()) {
                        if (presented) MonitorReadoutDismissBackdrop(onDismiss = {
                            dismissals++
                            presented = false
                        })
                        // The same sibling order and raised system layer as MonitorScreen.
                        Box(Modifier.fillMaxSize().zIndex(11f), contentAlignment = Alignment.Center) {
                            Text("Navigation", Modifier.size(54.dp)
                                .onGloballyPositioned { bounds = it.boundsInWindow() }
                                .monitorChromeClickable(enabled, onLongClick = if (hold) ({ holds++ }) else null) { taps++ }
                                .semantics { contentDescription = "Native chrome target" })
                        }
                    }
                }
            }
            val target = awaitTarget()
            val drawn = bounds
            pointer(target, if (hold) 750 else 60)
            scenario.onActivity {
                assertEquals(if (hold) 0 else 1, taps)
                assertEquals(if (hold) 1 else 0, holds)
                assertEquals(0, dismissals, "Enabled control keeps its original pointer")
                assertTrue(presented)
                enabled = false
            }
            settle()
            awaitTarget(enabled = false)
            scenario.onActivity { assertEquals(drawn, bounds, "Disabling cannot move or normalize the target") }
            pointer(target, 60)
            scenario.onActivity {
                assertEquals(if (hold) 0 else 1, taps, "Disabled input cannot fire the action")
                assertEquals(if (hold) 1 else 0, holds, "Disabled input cannot fire the hold action")
                assertEquals(1, dismissals, "Disabled raised chrome must return DOWN/UP to the actual backdrop")
                assertFalse(presented)
                enabled = true
                presented = true
            }
            settle()
            pointer(target, 60)
            scenario.onActivity {
                assertEquals(if (hold) 1 else 2, taps, "Re-enabled chrome gets its original tap once")
                assertEquals(1, dismissals)
                assertTrue(presented)
            }
        }
    }

    private fun findTarget(): AccessibilityNodeInfo? {
        fun find(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (node.contentDescription?.toString() == "Native chrome target") return node
            for (index in 0 until node.childCount) node.getChild(index)?.let { find(it)?.let { found -> return found } }
            return null
        }
        return InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.let(::find)
    }

    private fun awaitTarget(enabled: Boolean = true): AndroidRect {
        val deadline = SystemClock.uptimeMillis() + 5_000
        var last = AndroidRect()
        var stable = 0
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            val node = findTarget()
            val next = AndroidRect()
            node?.getBoundsInScreen(next)
            if (!next.isEmpty && next == last && node?.isEnabled == enabled) stable++ else stable = 0
            last = next
            if (stable >= 3) return next
            SystemClock.sleep(32)
        }
        error("Native target must publish stable bounds with enabled=$enabled within the original 5s readiness guard")
    }

    private fun pointer(target: AndroidRect, holdMillis: Long) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val down = SystemClock.uptimeMillis()
        fun send(action: Int) {
            val properties = arrayOf(MotionEvent.PointerProperties().apply {
                id = 0
                toolType = MotionEvent.TOOL_TYPE_FINGER
            })
            val coords = arrayOf(MotionEvent.PointerCoords().apply {
                x = target.exactCenterX()
                y = target.exactCenterY()
                pressure = 1f
                size = 1f
            })
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 1, properties, coords,
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
            try { assertTrue(automation.injectInputEvent(event, true), "Native dispatcher must accept $action") }
            finally { event.recycle() }
        }
        send(MotionEvent.ACTION_DOWN)
        SystemClock.sleep(holdMillis)
        send(MotionEvent.ACTION_UP)
        settle()
    }

    private fun settle() {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        SystemClock.sleep(180)
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }
}
