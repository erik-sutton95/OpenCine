package com.opencapture.monitorui

import android.graphics.Rect
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.opencine.cameracontrols.MediaSelectionTray
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Hardware pass 10.1: the media selection bar read "2 sel..." on a phone (Insta and Z Android).
 * The count is the bar's subject; the actions scroll before it is cut.
 */
@RunWith(AndroidJUnit4::class)
class MonitorSelectionTrayLabelTest {
    @Test fun countLabelIsNotCutOnAPhoneWidthBar() {
        ActivityScenario.launch(MonitorTestActivity::class.java).use { scenario ->
            var reference = 0
            scenario.onActivity { activity ->
                activity.setContent {
                    Column {
                        // A 360 dp phone less the page gutters leaves about 328 dp for the bar
                        // (the Samsung of the hardware pass, at its default display size, about 348 dp).
                        Box(Modifier.width(328.dp)) {
                            MediaSelectionTray(2, cacheEnabled = true, deleteEnabled = true,
                                onAll = {}, onClear = {}, onCache = {}, onStar = {}, onDelete = {}, onShare = {})
                        }
                        // The same words in the same type, unconstrained: the width the label needs.
                        Text("2 selected", Modifier.wrapContentWidth().onGloballyPositioned { reference = it.size.width },
                            maxLines = 1, style = MonitorTypography.text(10.5f, FontWeight.SemiBold))
                    }
                }
            }
            val label = assertNotNull(awaitLabel("2 selected"), "The selection count is exposed as text")
            val bounds = Rect().also(label::getBoundsInScreen)
            assertTrue(reference > 0, "The reference label was laid out")
            assertTrue(bounds.width() >= reference - 1,
                "The count label is cut: ${bounds.width()} px shown of $reference px needed")
        }
    }

    /** The tray's label node: the first of the two "2 selected" texts in tree order. */
    private fun awaitLabel(text: String): AccessibilityNodeInfo? {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            val root = InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow
            val matches = mutableListOf<AccessibilityNodeInfo>()
            fun visit(node: AccessibilityNodeInfo) {
                if (node.text?.toString() == text) matches += node
                for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
            }
            root?.let(::visit)
            // The first match in tree order is the tray's; the unconstrained copy comes after it.
            if (matches.size >= 2) return matches.first()
            SystemClock.sleep(100)
        }
        return null
    }
}
