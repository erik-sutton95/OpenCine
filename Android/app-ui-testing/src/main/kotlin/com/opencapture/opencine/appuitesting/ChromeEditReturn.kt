package com.opencapture.opencine.appuitesting

import com.opencapture.monitorui.ReviewLaunch
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import org.junit.Test

/**
 * S4: the chrome editor's Done returns to Display settings with the edited section in view, and
 * closing Settings returns to a working monitor that kept the edit.
 */
@Conformance
public abstract class ChromeEditReturn(subject: ConformanceApp) : ConformanceTest(subject) {
    @Test
    public fun doneReturnsToDisplaySettingsAndCloseToTheMonitor() {
        launch(ReviewLaunch(ReviewLaunch.Screen.LIVE))
        awaitTag(RECORD)
        tap(awaitTag(SETTINGS))
        selectDisplay()
        val edit = editButton(null)
        val editID = edit.tag!!
        tap(edit)

        awaitTag(DONE, 5_000)
        // The editor makes the monitor inert (no touch reaches it); only its badges and Done work.
        checkpoint("editing", operable = "monitor.chromeEdit.")
        // Rail eyes would hide the very controls the return is checked with.
        val eye = await("an eye for each element", 5_000) {
            val tag = it.tag ?: return@await false
            tag.startsWith(EYE) && tag != DONE && !tag.contains("rail", ignoreCase = true) && it.info.isClickable
        }
        val eyeID = eye.tag!!
        val before = eye.state
        tap(eye)
        val after = awaitTag(eyeID).state
        assertNotEquals(before, after, "The eye toggles its element")
        tap(awaitTag(DONE))

        val display = awaitTag(DISPLAY, 5_000)
        assertTrue(display.selected, "Done returns to the Display tab")
        reveal("The edited section") { it.tag == editID }
        checkpoint("after-done")
        tap(awaitTag(BACK))

        val record = awaitTag(RECORD, 5_000)
        val snapshot = snapshot()
        assertTrue(snapshot.nodes.none { it.visible && it.tag == DISPLAY }, "Closing Settings returns to the monitor")
        // As the Swift twin's `isHittable`: on screen and under nothing. Record itself stays disabled
        // without an admitted camera (a staged review has none) on both platforms.
        assertTrue(record.visible && !snapshot.covers(record), "The monitor works after the editor")
        checkpoint("monitor")
        tap(awaitTag(SETTINGS))
        selectDisplay()
        tap(editButton(editID))
        awaitTag(DONE, 5_000)
        assertEquals(after, awaitTag(eyeID).state, "The edit persists")
        // The edit outlives the app: undo it, or every later scenario on this device inherits it.
        tap(awaitTag(eyeID))
        assertEquals(before, awaitTag(eyeID).state)
        tap(awaitTag(DONE))
        awaitTag(DISPLAY, 5_000)
    }

    private fun selectDisplay() {
        val display = reveal(DISPLAY, container = TABS) { it.tag == DISPLAY }
        if (!display.selected) tap(display)
        await("$DISPLAY selected", 5_000) { it.tag == DISPLAY && it.selected }
    }

    /**
     * A Display section's Edit view ([id], else the first). Apps that fold each mode's section show
     * it once the section is opened, the way an operator reaches it.
     */
    private fun editButton(id: String?): UiNode {
        val wanted: (UiNode) -> Boolean = { node -> id?.let { node.tag == it } ?: (node.tag?.startsWith(EDIT) == true) }
        if (snapshot().nodes.none(wanted)) {
            val sectionID = id?.let { SECTION + it.removePrefix(EDIT) }
            val snapshot = snapshot()
            val section = snapshot.nodes.firstOrNull { node ->
                sectionID?.let { node.tag == it } ?: (node.tag?.startsWith(SECTION) == true)
            }
            // A folded card is its header alone.
            section?.let { card -> snapshot.descendants(card).firstOrNull { it.info.isClickable }?.let(::tap) }
        }
        return reveal("Display settings offer Edit view", 5_000, match = wanted)
    }

    private companion object {
        const val RECORD = "monitor.system.record"
        const val SETTINGS = "monitor.system.settings"
        const val DISPLAY = "monitor.settings.tab.Display"
        /** The portrait tab strip; a tab scrolled out of it is not in the tree until scrolled back. */
        const val TABS = "monitor.settings.tabs"
        const val EDIT = "monitor.settings.display.edit."
        const val SECTION = "monitor.settings.display.section."
        const val EYE = "monitor.chromeEdit."
        const val DONE = "monitor.chromeEdit.done"
        const val BACK = "monitor.page.back"
    }
}
