package com.opencapture.monitorui

import androidx.activity.compose.setContent
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
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
            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE)
            assertTrue(LiveAccessibilityTree.await(copy.message!!) != null)
            assertEquals(1, captures.get()); assertEquals(0, confirmations.get())
            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE_CANCEL)
            assertEquals(1, cancellations.get()); assertEquals(0, confirmations.get())
            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE)
            assertTrue(LiveAccessibilityTree.await(copy.message!!) != null)
            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE_CONFIRM)
            assertEquals(2, captures.get()); assertEquals(1, confirmations.get())
            assertEquals(1, cancellations.get())
        }
    }
}
