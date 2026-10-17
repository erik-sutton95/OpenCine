package com.opencapture.monitorui

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.media.MonitorConformPreview
import com.opencapture.opencine.media.MonitorPlaybackDeletionConfirmation
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED request enters actual shared playback chrome and its native popup accessibility.
 * No file, camera, store or media deletion is performed. */
@RunWith(AndroidJUnit4::class)
class MonitorPlaybackDeletionInputTest {
    @Test fun capturedRelatedCopyDialogCancelsAndConfirmsOnlyItsOriginalRequest() {
        val token = MonitorPlaybackItemToken(UUID.randomUUID(), 1)
        val copy = MonitorPlaybackDeletionConfirmation(title = "Remove SIMULATED clip?",
            message = "Its camera master and backup copies are removed too.")
        val captures = AtomicInteger(); val confirmations = AtomicInteger(); val cancellations = AtomicInteger()
        val actions = MonitorPlaybackActions(back = {}, play = { _, _ -> }, restart = {}, seekBy = { _, _ -> },
            mute = { _, _ -> }, loop = { _, _ -> }, conform = { _, _ -> }, adjacent = { _, _ -> },
            favorite = {}, share = {}, delete = null, beginScrub = { null }, updateScrub = { _, _ -> },
            updateFrameScrub = { _, _, _ -> }, commitScrub = {}, cancelScrub = { _, _ -> }).also {
            it.deletionConfirmation = MonitorPlaybackDeletionActions(capture = { admitted ->
                assertEquals(token, admitted); captures.incrementAndGet(); copy
            }, isCurrent = { it == copy.id }, confirm = { admitted ->
                assertEquals(copy.id, admitted); confirmations.incrementAndGet()
            }, cancel = { admitted -> assertEquals(copy.id, admitted); cancellations.incrementAndGet() })
        }
        val value = MonitorPlaybackPresentation(item = token, title = "SIMULATED", subtitle = "", source = null,
            metadata = emptyList(), aspect = 16f / 9f, ready = true, error = null, progress = null,
            position = 0f, duration = 10f, positionLabel = "00:00", durationLabel = "00:10", playing = false,
            reachedEnd = false, scrubbing = false, muted = false, looping = false, previous = false,
            next = false, favorite = false, conform = MonitorConformPreview.Source(), conformTarget = null)
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            scenario.moveToState(Lifecycle.State.RESUMED)
            scenario.onActivity { activity ->
                activity.setContent {
                    MonitorPlaybackScreen(value, actions, MonitorPlaybackPageSlots(), picture = {},
                        feedAssists = {}, canvasAssists = {}, tools = {}, assistInspector = {})
                }
            }
            click("Delete clip")
            assertTrue(awaitNode(copy.message!!) != null)
            assertEquals(1, captures.get()); assertEquals(0, confirmations.get())
            click("Cancel")
            assertEquals(1, cancellations.get()); assertEquals(0, confirmations.get())
            click("Delete clip")
            assertTrue(awaitNode(copy.message!!) != null)
            click("Delete")
            assertEquals(2, captures.get()); assertEquals(1, confirmations.get())
            assertEquals(1, cancellations.get())
        }
    }

    private fun click(label: String) {
        val found = requireNotNull(awaitNode(label)) { "Actual shared playback action did not mount: $label" }
        // A text label sits inside its merged clickable control; act on that control, as a screen reader does.
        val node = generateSequence(found) { it.parent }.firstOrNull { it.isClickable }
            ?: error("Actual shared playback action has no clickable control: $label")
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK), "Actual accessibility input refused: $label")
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }
    private fun awaitNode(label: String): AccessibilityNodeInfo? {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val automation = windowsAutomation()
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            instrumentation.waitForIdleSync()
            // Compose reports no change events to UiAutomation alone, so cached nodes go stale; read the live tree.
            if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
            for (window in automation.windows) {
                window.root?.let { root -> find(root, label)?.let { return it } }
            }
            Thread.yield()
        } while (SystemClock.uptimeMillis() < deadline)
        return null
    }
    /** UiAutomation lists no windows until it opts in to interactive windows; the playback chrome is its own popup window. */
    private fun windowsAutomation(): UiAutomation {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val info = automation.serviceInfo
        if ((info.flags and AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS) == 0) {
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            automation.serviceInfo = info
        }
        return automation
    }
    private fun find(node: AccessibilityNodeInfo, label: String): AccessibilityNodeInfo? {
        if (node.text?.toString() == label || node.contentDescription?.toString() == label) return node
        for (index in 0 until node.childCount) node.getChild(index)?.let { child ->
            find(child, label)?.let { return it }
        }
        return null
    }
}
