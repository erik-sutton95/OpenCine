package com.opencapture.opencine.cameracontrols

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderTab
import com.opencapture.opencine.vocabulary.LadderWrite
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED native accessibility input drives the actual common ladder drum. */
@RunWith(AndroidJUnit4::class)
class LadderSheetHostTest {
    @Test fun observationsPreviewAndDismissalDoNotWriteWhileExplicitInputWritesOnce() {
        var selection by mutableStateOf<String?>(null)
        var previewPosition by mutableStateOf<Float?>(null)
        var presented by mutableStateOf(true)
        val writes = mutableListOf<LadderWrite<String>>()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    if (presented) LadderSheet(
                        LadderSheetPresentation("ISO", "Sensitivity", listOf(
                            LadderTab("ISO", "iso", CaptureLadder(selection, listOf("400", "800")), applyOnActivate = false))),
                        enabled = true,
                        onWrite = { writes += it; selection = it.value },
                        onClose = { presented = false }, chromeless = true,
                        host = LadderSheetHost(0, selection, LadderSheetDrum.Labels,
                            previewPosition = previewPosition, onSelectTab = {}))
                }
            }
            node("Choose value")
            scenario.onActivity { assertTrue("Unknown must not write the first detent", writes.isEmpty()); selection = "800" }
            node("800")
            scenario.onActivity {
                assertTrue("External observation cannot echo a write", writes.isEmpty())
                selection = "400"; previewPosition = 0f
            }
            val preview = node("400")
            val arguments = Bundle().apply { putFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE, 1f) }
            preview.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id, arguments)
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertTrue("Preview highlighting cannot send", writes.isEmpty())
                presented = false
            }
            instrumentation.waitForIdleSync()
            scenario.onActivity {
                assertTrue("Cancel/dismiss cannot send", writes.isEmpty())
                previewPosition = null; presented = true
            }
            assertTrue(node("400", AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id)
                .performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS.id, arguments))
            node("800")
            scenario.onActivity {
                assertEquals(listOf(LadderWrite("iso", "800")), writes)
                selection = "400"
            }
            node("400")
            scenario.onActivity { assertEquals("Later report must not replay the edit", 1, writes.size) }
        }
    }

    private fun node(label: String, requiredAction: Int? = null): AccessibilityNodeInfo {
        var lastActions: List<Int>? = null
        fun find(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (node.contentDescription?.toString() == label) {
                val actions = node.actionList.map { it.id }
                if (requiredAction == null || requiredAction in actions) return node
                if (actions != lastActions) {
                    println("SIMULATED waiting for native input action: label=$label actions=$actions required=$requiredAction")
                    lastActions = actions
                }
            }
            for (i in 0 until node.childCount) node.getChild(i)?.let { find(it)?.let { found -> return found } }
            return null
        }
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            automation.rootInActiveWindow?.let { find(it)?.let { found -> return found } }
            SystemClock.sleep(20)
        }
        error("Actual ladder node $label was not published")
    }
}
