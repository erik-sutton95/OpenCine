package com.opencapture.opencine.appuitesting

import com.opencapture.monitorui.MonitorPlaybackCopy
import com.opencapture.monitorui.ReviewLaunch
import com.opencapture.monitorui.settings.MonitorSettingsTab
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * S3: every destructive confirmation can be cancelled, with its Cancel button and with the system
 * Back, and cancelling changes nothing: the clip stays listed, the player stays on it and still
 * offers Delete. Camera deletion runs where the profile declares `clipDelete`; Clear cache everywhere.
 */
@Conformance
public abstract class ConfirmationCancel(subject: ConformanceApp) : ConformanceTest(subject) {
    @Test
    public fun cancellingPlaybackDeleteKeepsTheClip() {
        requireClipDelete()
        launch(ReviewLaunch(ReviewLaunch.Screen.PLAYBACK, source = ReviewLaunch.Source.CAMERA, connected = true))
        awaitTag(TITLE)
        val title = awaitTag(TITLE).label
        for (cancel in listOf(true, false)) {
            tap(awaitLabel(DELETE_CLIP, 15_000))
            awaitLabel(DELETE, 5_000)
            checkpoint("playback-delete-confirmation")
            dismiss(cancel) { it.label == DELETE && it.info.isClickable }
            assertEquals(title, awaitTag(TITLE).label, "Cancelling keeps the player on the same clip")
            assertTrue(awaitLabel(DELETE_CLIP).enabled, "Delete is still offered while connected")
        }
        checkpoint("playback-delete-cancelled")
    }

    @Test
    public fun cancellingGalleryDeleteKeepsTheSelection() {
        requireClipDelete()
        launch(ReviewLaunch(ReviewLaunch.Screen.MEDIA, source = ReviewLaunch.Source.CAMERA, connected = true))
        val gallery = MediaGalleryProbe(this)
        awaitTag(MediaGalleryProbe.GALLERY)
        if (gallery.settledAnchor() == null) fail("The staged camera clips must show")
        val (first, second) = gallery.sweepPair() ?: fail("Two neighbouring clips wholly in view are required")
        pressAndDrag(first.bounds, second.bounds)
        awaitLabel("2 selected", 5_000)
        // The clips listed once selected (a sweep near an edge may scroll the gallery): cancelling keeps them.
        val listed = gallery.visibleClips().map { it.id }
        for (cancel in listOf(true, false)) {
            val delete = awaitLabel(DELETE_SELECTED, 5_000)
            assertTrue(delete.enabled, "Connected camera clips can be deleted")
            tap(delete)
            awaitLabel(DELETE, 5_000)
            checkpoint("gallery-delete-confirmation")
            dismiss(cancel) { it.label == DELETE && it.info.isClickable }
            assertTrue(snapshot().nodes.any { it.visible && it.label == "2 selected" }, "Cancelling keeps the selection")
            assertEquals(listed, gallery.visibleClips().map { it.id }, "Cancelling keeps every clip listed")
        }
    }

    @Test
    public fun cancellingClearCacheKeepsStorageSettings() {
        launch(ReviewLaunch(ReviewLaunch.Screen.SETTINGS, settingsTab = MonitorSettingsTab.STORAGE))
        awaitTag(STORAGE)
        for (cancel in listOf(true, false)) {
            tap(reveal("Clear cache") { it.label == "Clear" && it.info.isClickable })
            awaitLabel("Clear cache?", 5_000)
            checkpoint("clear-cache-confirmation")
            dismiss(cancel) { it.label == "Clear cache?" }
            assertTrue(awaitTag(STORAGE).selected, "Cancelling stays on Storage")
            assertTrue(snapshot().nodes.any { it.visible && it.label == "Clear" && it.info.isClickable }, "Clear stays offered")
        }
    }

    private fun dismiss(cancel: Boolean, confirm: (UiNode) -> Boolean) {
        if (cancel) cancelConfirmation(confirm) else backOutOfConfirmation(confirm)
    }

    private fun requireClipDelete() {
        assumeTrue("The camera cannot delete clips", profile.capabilities.clipDelete)
    }

    private companion object {
        const val TITLE = "monitor.playback.title"
        const val STORAGE = "monitor.settings.tab.Storage"
        const val DELETE = "Delete"
        const val DELETE_CLIP = MonitorPlaybackCopy.DELETE
        const val DELETE_SELECTED = "Delete selected clips"
    }
}
