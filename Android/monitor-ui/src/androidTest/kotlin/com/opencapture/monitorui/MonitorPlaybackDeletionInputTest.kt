package com.opencapture.monitorui

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
        val node = requireNotNull(awaitNode(label)) { "Actual shared playback action did not mount: $label" }
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK), "Actual accessibility input refused: $label")
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }
    private fun awaitNode(label: String): AccessibilityNodeInfo? {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val deadline = SystemClock.uptimeMillis() + 5_000
        do {
            instrumentation.waitForIdleSync()
            for (window in instrumentation.uiAutomation.windows) {
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
}
