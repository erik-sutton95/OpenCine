package com.opencapture.monitorui

import android.graphics.Rect
import android.accessibilityservice.AccessibilityServiceInfo
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.cameracontrols.LUTPicker
import com.opencapture.opencine.cameracontrols.LutPickerEntry
import com.opencapture.opencine.cameracontrols.LutPickerLibrary
import kotlin.math.abs
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED external selection through the mounted shared picker and its actual native wheel. */
@RunWith(AndroidJUnit4::class)
class LutExternalSelectionInputTest {
    // Catches an appear-only wheel or a stale resting row overwriting an external change.
    @Test fun mountedPickerCentersExternalSelectionWithoutRestoringItsOldLook() {
        val entries = listOf("Mono", "Contrast", "Warm", "Cool").map { LutPickerEntry(it, it) }
        val selection = mutableStateOf("Mono")
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            scenario.moveToState(Lifecycle.State.RESUMED)
            scenario.onActivity { activity ->
                activity.setContent {
                    LUTPicker(listOf(LutPickerLibrary(title = "Creative", entries = entries,
                        isCurrent = true, selectedId = selection.value,
                        onSelect = { selection.value = it.id })), modifier = Modifier.height(220.dp))
                }
            }
            val initial = assertNotNull(awaitLabel("Mono"), "Initial row missing; native labels: ${nativeLabels()}")
            val center = Rect().also(initial::getBoundsInScreen).centerY()
            for (next in listOf("Cool", "Mono", "Warm")) {
                instrumentation.runOnMainSync { selection.value = next }
                val deadline = SystemClock.uptimeMillis() + 5_000
                var offset: Int? = null
                do {
                    val row = awaitLabel(next)
                    offset = row?.let { Rect().also(it::getBoundsInScreen).centerY() - center }
                    if (offset != null && abs(offset) < 3) break
                    Thread.yield()
                } while (SystemClock.uptimeMillis() < deadline)
                assertTrue(offset != null && abs(offset) < 3,
                    "Mounted LUT wheel did not center $next; vertical offset: $offset")
                instrumentation.waitForIdleSync()
                assertEquals(next, selection.value, "The resting row overwrote the external look")
            }
        }
    }

    private fun awaitLabel(label: String): AccessibilityNodeInfo? {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val automation = instrumentation.uiAutomation
        val info = automation.serviceInfo
        info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
        automation.serviceInfo = info
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            instrumentation.waitForIdleSync()
            if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
            for (window in automation.windows) {
                window.root?.let { root -> find(root, label)?.let { return it } }
            }
            Thread.yield()
        } while (SystemClock.uptimeMillis() < deadline)
        return null
    }

    private fun find(node: AccessibilityNodeInfo, label: String): AccessibilityNodeInfo? {
        if (node.text?.toString() == label || node.contentDescription?.toString() == label) return node
        for (index in 0 until node.childCount) node.getChild(index)?.let { child ->
            find(child, label)?.let { return it }
        }
        return null
    }

    private fun nativeLabels(): List<String> {
        val result = mutableListOf<String>()
        fun visit(node: AccessibilityNodeInfo) {
            if (result.size >= 100) return
            result += "${node.text}/${node.contentDescription}"
            for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
        }
        InstrumentationRegistry.getInstrumentation().uiAutomation.windows.forEach { it.root?.let(::visit) }
        return result
    }
}
