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
import kotlin.test.assertEquals
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
            val node = titled()
            assertTrue(node.isCheckable, "the titled node must be the switch")
            assertTrue(node.isChecked, "a switch drawn on must read checked")
            assertEquals("On", node.stateDescription?.toString())
            assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK), "one activation toggles the row")
            val off = titled()
            assertTrue(off.isCheckable)
            assertTrue(!off.isChecked, "after the toggle the switch reads off")
            assertEquals("Off", off.stateDescription?.toString())
        }
    }

    /** The node UI Automator and TalkBack land on: the one whose text is the title. */
    private fun titled(): AccessibilityNodeInfo {
        val node = assertNotNull(LiveAccessibilityTree.await(title))
        assertEquals(title, node.text?.toString() ?: node.contentDescription?.toString())
        return node
    }
}
