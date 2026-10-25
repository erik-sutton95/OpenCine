package com.opencapture.opencine.cameracontrols

import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.opencapture.monitorui.settings.MonitorDisplayChoice
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Hardware pass 3.5: the empty watcher passcode field drew nothing (no outline or placeholder) and
 * its editable node had no name. SIMULATED sharing values mount the actual shared Sharing rows.
 */
@RunWith(AndroidJUnit4::class)
class SettingsPasscodeFieldTest {
    private val title = "Watcher Passcode"

    @Test fun anEmptyPasscodeFieldIsNamedAndOutlined() {
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                activity.setContent { SettingsSharing(source(), feedback = {}) }
            }
            val field = awaitNode { it.isEditable }
            // Compose puts a field's name on the editable node, or on a child of it that TalkBack
            // reads with the field (and UI Automator counts against NAF).
            val named = generateSequence(listOf(field)) { level -> level.flatMap { node ->
                (0 until node.childCount).mapNotNull(node::getChild) }.takeIf { it.isNotEmpty() } }.flatten()
                .any { it.contentDescription?.toString() == title }
            assertTrue("the editable passcode node reads its row title: ${field.className} desc=${field.contentDescription}", named)
            val bounds = android.graphics.Rect().also(field::getBoundsInScreen)
            val density = InstrumentationRegistry.getInstrumentation().targetContext.resources.displayMetrics.density
            assertTrue("the outlined field is a real touch target, not a hairline: $bounds",
                bounds.height() >= (30 * density).toInt())
        }
    }

    private fun source() = MonitorSettingsSharingSource(
        sharingTitle = "Share This Feed", sharingHelp = "help", sharing = null, setSharing = null,
        unavailable = "Connect a camera to share",
        priority = MonitorSettingsChoiceSource("Broadcast Priority", null,
            listOf(MonitorDisplayChoice("0", "Low latency"), MonitorDisplayChoice("1", "Quality")), "0", {}, segmented = true),
        passcodeTitle = title, passcodeHelp = "help", passcode = "", setPasscode = {},
        controlRequestsTitle = "Control Requests", controlRequestsHelp = "help", controlRequests = false,
        setControlRequests = {}, declineTitle = "Decline", grantTitle = "Grant", takeBackTitle = "Take Back",
    )

    private fun awaitNode(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        val end = SystemClock.uptimeMillis() + 5_000
        do {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            nodes().firstOrNull { it.isVisibleToUser && matches(it) }?.let { return it }
            SystemClock.sleep(16)
        } while (SystemClock.uptimeMillis() < end)
        throw AssertionError("No matching node: " + nodes().joinToString { "${it.text}/${it.contentDescription}" })
    }

    private fun nodes(): List<AccessibilityNodeInfo> {
        val pending = ArrayDeque<AccessibilityNodeInfo>()
        InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.let(pending::add)
        val result = mutableListOf<AccessibilityNodeInfo>()
        while (pending.isNotEmpty() && result.size < 5_000) {
            val node = pending.removeFirst()
            result += node
            for (i in 0 until node.childCount) node.getChild(i)?.let(pending::add)
        }
        return result
    }
}
