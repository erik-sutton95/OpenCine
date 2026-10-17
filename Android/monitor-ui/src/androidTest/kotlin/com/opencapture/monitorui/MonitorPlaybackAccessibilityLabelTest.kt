package com.opencapture.monitorui

import android.os.Build
import androidx.activity.compose.setContent
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.media.MonitorConformPreview
import com.opencapture.opencine.media.MonitorPlaybackDeletionConfirmation
import com.opencapture.opencine.media.MonitorPlaybackItemToken
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * SIMULATED values mount the actual shared playback screen and read what TalkBack reads. Every
 * expected string comes from [MonitorPlaybackCopy], which `Fixtures/playback-copy.tsv` ties to the
 * Swift copy; `MonitorPlaybackAccessibilityLabelTests` (Swift MonitorUITests) reads the same strings
 * from the SwiftUI screen. No file, camera or media is touched.
 */
@RunWith(AndroidJUnit4::class)
class MonitorPlaybackAccessibilityLabelTest {
    private val item = MonitorPlaybackItemToken(UUID.randomUUID(), 1)
    private val captures = AtomicInteger()
    private val confirmed = CopyOnWriteArrayList<UUID>()
    private val cancelled = CopyOnWriteArrayList<UUID>()
    private val deleted = CopyOnWriteArrayList<MonitorPlaybackItemToken>()

    @Test fun chromeTransportScrubberAndInfoReadTheSharedCopy() = mount(actions(typed = null)) {
        for (label in listOf(
            MonitorPlaybackCopy.BACK_TO_MEDIA, MonitorPlaybackCopy.FAVORITE, MonitorPlaybackCopy.CLIP_INFORMATION,
            MonitorPlaybackCopy.SHARE, MonitorPlaybackCopy.DELETE, MonitorPlaybackCopy.BACK_FIFTEEN,
            MonitorPlaybackCopy.transport(reachedEnd = false, playing = false), MonitorPlaybackCopy.FORWARD_FIFTEEN,
            MonitorPlaybackCopy.CONFORM_PREVIEW, MonitorPlaybackCopy.muteToggle(muted = false), MonitorPlaybackCopy.LOOP,
            MonitorPlaybackCopy.HIDE_CONTROLS, MonitorPlaybackCopy.PREVIOUS_CLIP, MonitorPlaybackCopy.NEXT_CLIP,
            MonitorPlaybackCopy.POSITION,
        )) assertNotNull(LiveAccessibilityTree.await(label), "The actual playback node must read: $label")
        // The gesture well has no screen reader action, so it carries a test tag, not a label.
        assertNull(LiveAccessibilityTree.await("Playback picture controls", 0))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            assertEquals(MonitorPlaybackCopy.toggleValue(true),
                LiveAccessibilityTree.await(MonitorPlaybackCopy.LOOP)?.stateDescription?.toString())
            assertEquals(MonitorPlaybackCopy.positionValue(7.9f.toDouble()),
                LiveAccessibilityTree.await(MonitorPlaybackCopy.POSITION)?.stateDescription?.toString())
        }

        LiveAccessibilityTree.click(MonitorPlaybackCopy.CONFORM_PREVIEW)
        assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.CONFORM_TITLE))
        assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.conformSubtitle(60.0)))
        LiveAccessibilityTree.click(MonitorPlaybackCopy.CLOSE_CONFORM_PREVIEW)
        assertTrue(LiveAccessibilityTree.awaitGone(MonitorPlaybackCopy.CONFORM_TITLE), "Closing the conform panel must remove it")

        LiveAccessibilityTree.click(MonitorPlaybackCopy.CLIP_INFORMATION)
        assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.CLOSE_CLIP_INFORMATION))
        assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.CLIP_INFORMATION_TITLE))
        LiveAccessibilityTree.click(MonitorPlaybackCopy.CLOSE_CLIP_INFORMATION)
        assertTrue(LiveAccessibilityTree.awaitGone(MonitorPlaybackCopy.CLOSE_CLIP_INFORMATION), "Closing the sheet must remove it")

        LiveAccessibilityTree.click(MonitorPlaybackCopy.HIDE_CONTROLS)
        assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.SHOW_CONTROLS))
        assertTrue(LiveAccessibilityTree.awaitGone(MonitorPlaybackCopy.FAVORITE), "Clean view hides the header chrome")
    }

    @Test fun capturedDeletionConfirmationReadsTheSharedCopyAndSettlesOnlyItsRequest() {
        val copy = MonitorPlaybackDeletionConfirmation(title = "Remove this SIMULATED clip?",
            message = "Its camera master and backup copies are removed too.")
        mount(actions(typed = copy)) {
            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE)
            assertNotNull(LiveAccessibilityTree.await(copy.title))
            assertNotNull(LiveAccessibilityTree.await(copy.message!!))
            assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.DELETE_CONFIRM))
            assertEquals(1, captures.get())
            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE_CANCEL)
            assertEquals(listOf(copy.id), cancelled.toList()); assertEquals(emptyList(), confirmed.toList())
            assertTrue(LiveAccessibilityTree.awaitGone(copy.title))

            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE)
            assertNotNull(LiveAccessibilityTree.await(copy.title))
            LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE_CONFIRM)
            assertEquals(listOf(copy.id), confirmed.toList()); assertEquals(2, captures.get())
            assertEquals(listOf(copy.id), cancelled.toList())
        }
    }

    @Test fun untypedDeletionConfirmationFallsBackToTheSharedTitle() = mount(actions(typed = null)) {
        LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE)
        assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.DELETE_CONFIRMATION_TITLE))
        assertNotNull(LiveAccessibilityTree.await(MonitorPlaybackCopy.DELETE_CANCEL))
        LiveAccessibilityTree.click(MonitorPlaybackCopy.DELETE_CONFIRM)
        assertEquals(listOf(item), deleted.toList())
        assertTrue(LiveAccessibilityTree.awaitGone(MonitorPlaybackCopy.DELETE_CONFIRMATION_TITLE))
    }

    private fun actions(typed: MonitorPlaybackDeletionConfirmation?) =
        MonitorPlaybackActions(back = {}, play = { _, _ -> }, restart = {}, seekBy = { _, _ -> },
            mute = { _, _ -> }, loop = { _, _ -> }, conform = { _, _ -> }, adjacent = { _, _ -> },
            favorite = {}, share = {}, delete = if (typed == null) { admitted -> deleted.add(admitted) } else null,
            beginScrub = { null }, updateScrub = { _, _ -> }, updateFrameScrub = { _, _, _ -> }, commitScrub = {},
            cancelScrub = { _, _ -> }).also { actions ->
            if (typed != null) actions.deletionConfirmation = MonitorPlaybackDeletionActions(
                capture = { admitted -> assertEquals(item, admitted); captures.incrementAndGet(); typed },
                isCurrent = { it == typed.id }, confirm = { confirmed.add(it) }, cancel = { cancelled.add(it) })
        }

    private fun mount(actions: MonitorPlaybackActions, body: () -> Unit) {
        val value = MonitorPlaybackPresentation(item = item, title = "SIMULATED clip", subtitle = "SIMULATED detail",
            source = null, metadata = listOf(MonitorMetadataRow("Codec", "SIMULATED")), aspect = 16f / 9f,
            ready = true, error = null, progress = null, position = 7.9f, duration = 30f, positionLabel = "00:07",
            durationLabel = "00:30", playing = false, reachedEnd = false, scrubbing = false, muted = false,
            looping = true, previous = true, next = true, favorite = false,
            conform = MonitorConformPreview.Source(captureRate = 60.0), conformTarget = null)
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            scenario.moveToState(Lifecycle.State.RESUMED)
            scenario.onActivity { activity ->
                activity.setContent {
                    MonitorPlaybackScreen(value, actions, MonitorPlaybackPageSlots(), picture = {},
                        feedAssists = {}, canvasAssists = {}, tools = {}, assistInspector = {})
                }
            }
            body()
        }
    }
}
