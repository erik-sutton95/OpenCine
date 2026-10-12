package com.opencapture.opencine.appuitesting

import com.opencapture.monitorui.ReviewLaunch
import com.opencapture.monitorui.settings.MonitorSettingsTab
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.junit.Test

/**
 * S5: on every staged screen, and with a confirmation presented, the accessibility tree TalkBack
 * reads is finite (a bounded walk completes) and every control the app names `monitor.*` has a label.
 */
@Conformance
public abstract class AccessibilityTraversal(subject: ConformanceApp) : ConformanceTest(subject) {
    @Test
    public fun everyStagedScreenHasAFiniteLabelledTree() {
        for (screen in ReviewLaunch.Screen.entries) {
            launch(ReviewLaunch(screen))
            await("${screen.wire} shows controls") { it.info.isClickable }
            // The chrome editor makes the monitor inert; only its badges and Done work (S4).
            val operable = if (screen == ReviewLaunch.Screen.CHROME_EDIT) "monitor.chromeEdit." else "monitor."
            assertTree(screen.wire, operable)
        }
    }

    @Test
    public fun aPresentedConfirmationHasAFiniteLabelledTree() {
        launch(ReviewLaunch(ReviewLaunch.Screen.SETTINGS, settingsTab = MonitorSettingsTab.STORAGE))
        tap(reveal("Clear cache") { it.label == "Clear" && it.info.isClickable })
        awaitLabel("Clear cache?", 5_000)
        assertTree("clear-cache-confirmation", "monitor.")
    }

    private fun assertTree(name: String, operable: String) {
        val snapshot = snapshot(NODE_BOUND)
        assertTrue(snapshot.complete, "$name: the tree has more than $NODE_BOUND nodes")
        val unlabelled = snapshot.nodes.filter {
            it.visible && it.tag?.startsWith("monitor.") == true && it.isControl() && it.label.isBlank()
        }.map { it.tag }
        assertEquals(emptyList(), unlabelled, "$name: controls without a label")
        checkpoint(name, operable)
    }

    private fun UiNode.isControl(): Boolean =
        info.isClickable || info.isLongClickable || info.isCheckable || info.isEditable || info.rangeInfo != null

    private companion object {
        /** More nodes than any staged screen has; a tree this large is a runaway. */
        const val NODE_BOUND = 5_000
    }
}
