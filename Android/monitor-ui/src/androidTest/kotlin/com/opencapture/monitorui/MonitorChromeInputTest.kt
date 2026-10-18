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

    @Test fun disabledChildLabelKeepsOriginalNativeTargetGroupingAndBounds() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            var enabled by mutableStateOf(true)
            var presented by mutableStateOf(true)
            var dismissals = 0
            var feedback = 0
            val selections = mutableListOf<Int>()
            val label = "Child-labelled native target"
            scenario.onActivity { activity ->
                activity.setContent {
                    Box(Modifier.fillMaxSize()) {
                        if (presented) MonitorReadoutDismissBackdrop(onDismiss = {
                            dismissals++
                            presented = false
                        })
                        Box(Modifier.fillMaxSize().zIndex(11f), contentAlignment = Alignment.Center) {
                            // Same container/child label composition as MonitorStarRating. A 54dp
                            // fixture avoids Android's 48dp accessibility touch expansion of its 44dp control.
                            Box(Modifier.size(54.dp).monitorChromeClickable(enabled,
                                onClickFeedback = { feedback++ }) { selections += 1 },
                                contentAlignment = Alignment.Center) {
                                MonitorIcon(MonitorIcon.STAR, label, Modifier.size(22.dp))
                            }
                        }
                    }
                }
            }
            val target = awaitTarget(label = label)
            assertGroupedTarget(label, enabled = true, target)
            pointer(target, 60)
            scenario.onActivity {
                assertEquals(listOf(1), selections)
                assertEquals(1, feedback)
                assertEquals(0, dismissals)
                assertTrue(presented)
                enabled = false
            }
            settle()
            assertEquals(target, awaitTarget(enabled = false, label = label),
                "Disabling must preserve the labelled container's original native bounds")
            assertGroupedTarget(label, enabled = false, target)
            pointer(target, 60)
            scenario.onActivity {
                assertEquals(listOf(1), selections, "Disabled stars cannot select a rating")
                assertEquals(1, feedback, "Disabled stars cannot emit selection feedback")
                assertEquals(1, dismissals, "The real backdrop receives the disabled control's DOWN/UP")
                assertFalse(presented)
                enabled = true
                presented = true
            }
            settle()
            assertEquals(target, awaitTarget(label = label), "Re-enable must preserve the original grouped target")
            assertGroupedTarget(label, enabled = true, target)
            pointer(target, 60)
            scenario.onActivity {
                assertEquals(listOf(1, 1), selections, "Re-enabled star selects once")
                assertEquals(2, feedback)
                assertEquals(1, dismissals)
                assertTrue(presented)
            }
        }
    }

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

    private fun findTarget(label: String = "Native chrome target"): AccessibilityNodeInfo? {
        fun find(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (node.contentDescription?.toString() == label) return node
            for (index in 0 until node.childCount) node.getChild(index)?.let { find(it)?.let { found -> return found } }
            return null
        }
        val labelled = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.let(::find)
        var target = labelled
        // Android exposes child label nodes inside a merged group. The native screen-reader
        // focus flag identifies the actual target; never synthesize or expand its bounds.
        while (target != null) {
            if (target.isScreenReaderFocusable) return target
            target = target.parent
        }
        return labelled
    }

    private fun assertGroupedTarget(label: String, enabled: Boolean, bounds: AndroidRect) {
        val labels = mutableListOf<AccessibilityNodeInfo>()
        fun visit(node: AccessibilityNodeInfo) {
            if (node.contentDescription?.toString() == label) labels += node
            for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
        }
        checkNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow).let(::visit)
        assertEquals(1, labels.size, "One native target must group the container and its child label")
        val node = checkNotNull(findTarget(label))
        assertTrue(node.isScreenReaderFocusable, "Android must expose the labelled container as a screen-reader target")
        assertEquals(enabled, node.isEnabled, "Disabled state must belong to the actual labelled native node")
        assertEquals(1, node.childCount, "The native group retains its one labelled icon child")
        val actual = AndroidRect()
        node.getBoundsInScreen(actual)
        assertEquals(bounds, actual)
    }

    private fun awaitTarget(enabled: Boolean = true, label: String = "Native chrome target"): AndroidRect {
        val deadline = SystemClock.uptimeMillis() + 5_000
        var last = AndroidRect()
        var stable = 0
        var lastEnabled: Boolean? = null
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            val node = findTarget(label)
            lastEnabled = node?.isEnabled
            val next = AndroidRect()
            node?.getBoundsInScreen(next)
            if (!next.isEmpty && next == last && node?.isEnabled == enabled) stable++ else stable = 0
            last = next
            if (stable >= 3) return next
            SystemClock.sleep(32)
        }
        error("Native target $label must publish stable bounds with enabled=$enabled within the original 5s readiness guard; " +
            "last enabled=$lastEnabled bounds=$last")
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
