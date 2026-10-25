package com.opencapture.monitorui

import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.monitorui.settings.MonitorCacheSettings
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Hardware pass 7.3: the Storage caching switch was drawn on while the node a reader finds by its
 * title reported checked=false and checkable=false. The title and the switch are one node now.
 */
@RunWith(AndroidJUnit4::class)
class MonitorSettingsSwitchAccessibilityTest {
    private val title = "Full Resolution Caching"

    @Test fun theTitledNodeIsTheSwitchAndReportsItsDrawnState() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent {
                    var on by remember { mutableStateOf(true) }
                    MonitorCacheSettings(cacheOriginals = on, sizeLabel = "120.3 MB", cacheHelp = "Help text",
                        scopeHelp = "Scope", clearHelp = "Clear", onCacheOriginals = { on = it }, clear = {})
                }
            }
            val row = switchOf(titled())
            assertTrue(row.isChecked, "a switch drawn on must read checked: ${describe(row)}")
            assertTrue(row.performAction(AccessibilityNodeInfo.ACTION_CLICK), "one activation toggles the row")
            // Compose publishes the new state on its next frame; read the live tree until it lands.
            val deadline = android.os.SystemClock.uptimeMillis() + 5_000
            var off = switchOf(titled())
            while (off.isChecked && android.os.SystemClock.uptimeMillis() < deadline) {
                android.os.SystemClock.sleep(16)
                off = switchOf(titled())
            }
            assertTrue(!off.isChecked, "after the toggle the switch reads off: ${describe(off)}")
        }
    }

    /**
     * The control a screen reader focuses for the title: the title text itself or the clickable
     * row that contains it (Compose reports the row and lets TalkBack read its children). It must
     * be the checkable switch, not a plain label beside it.
     */
    private fun switchOf(title: AccessibilityNodeInfo): AccessibilityNodeInfo {
        val control = generateSequence(title) { it.parent }.firstOrNull { it.isClickable || it.isCheckable }
        assertNotNull(control, "the title must sit inside its switch, not beside it: ${describe(title)}")
        assertTrue(control.isCheckable, "the titled control must be the switch: ${describe(control)}")
        return control
    }

    private fun describe(node: AccessibilityNodeInfo): String =
        "class=${node.className} text=${node.text} desc=${node.contentDescription} checkable=${node.isCheckable} " +
            "checked=${node.isChecked} clickable=${node.isClickable} children=${node.childCount} " +
            "parent=${node.parent?.let { "${it.className}/${it.text}/${it.contentDescription}/checkable=${it.isCheckable}" }}"

    /** The node UI Automator finds by the title. */
    private fun titled(): AccessibilityNodeInfo = assertNotNull(LiveAccessibilityTree.await(title))
}
