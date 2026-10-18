package com.opencapture.opencine.cameracontrols

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** SIMULATED host values and callbacks exercise the actual shared panel's native buttons. */
@RunWith(AndroidJUnit4::class)
class MonitorIndependentSettingsNativeTest {
    private enum class Target { FIRST, SECOND }

    @Test fun openingClosingAndReorderingNeverSelects() = withPanel { fixture, scenario ->
        assertFalse(option("first", 0).isSelected)
        assertTrue(option("second", 1).isSelected)
        assertEquals(listOf("First", "Second"), titles())
        scenario.onActivity { fixture.reversed = true }
        val end = SystemClock.uptimeMillis() + 5_000
        while (titles() != listOf("Second", "First") && SystemClock.uptimeMillis() < end) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            SystemClock.sleep(16)
        }
        assertEquals(listOf("Second", "First"), titles())
        scenario.onActivity { fixture.visible = false }
        val closeEnd = SystemClock.uptimeMillis() + 5_000
        while (nodes().any { tag(it) == "monitor.independentSettings.first.option.0" } && SystemClock.uptimeMillis() < closeEnd) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            SystemClock.sleep(16)
        }
        assertFalse(nodes().any { tag(it) == "monitor.independentSettings.first.option.0" })
        assertTrue(fixture.requests.isEmpty())
        assertTrue(fixture.refusals.isEmpty())
    }

    @Test fun selectionSendsOnlyTheTappedRowAndExactOptionOnce() = withPanel { fixture, _ ->
        click(option("first", 1))
        assertEquals(listOf(Target.FIRST), fixture.requests)
        assertEquals(listOf(" On "), fixture.options)
        click(option("second", 0))
        assertEquals(listOf(Target.FIRST, Target.SECOND), fixture.requests)
        assertEquals(listOf(" On ", "off"), fixture.options)
        assertFalse("Sending must not invent an observed current", option("first", 1).isSelected)
    }

    @Test fun unavailableRowReportsItsHostReasonWithoutSending() = withPanel { fixture, scenario ->
        scenario.onActivity { fixture.secondAvailable = false }
        awaitNode { tag(it) == "monitor.independentSettings.second.reason" }
        click(option("second", 1))
        assertTrue(fixture.requests.isEmpty())
        assertEquals(listOf("second"), fixture.refusals)
        assertEquals(listOf("Host refusal"), fixture.reasons)
    }

    @Test fun interactionAndCurrentSourceRefuseNativeActions() = withPanel { fixture, scenario ->
        val mounted = option("first", 1)
        scenario.onActivity { fixture.sourceCurrent = false }
        click(mounted)
        assertTrue(fixture.requests.isEmpty())
        scenario.onActivity { fixture.sourceCurrent = true; fixture.enabled = false }
        val disabled = awaitNode { tag(it) == "monitor.independentSettings.first.option.1" && !it.isEnabled }
        disabled.performAction(AccessibilityNodeInfo.ACTION_CLICK)
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        assertTrue(fixture.requests.isEmpty())
        assertTrue(fixture.refusals.isEmpty())
    }

    private class Fixture {
        var reversed by mutableStateOf(false)
        var visible by mutableStateOf(true)
        var enabled by mutableStateOf(true)
        var secondAvailable by mutableStateOf(true)
        var sourceCurrent = true
        val requests = mutableListOf<Target>()
        val options = mutableListOf<String>()
        val refusals = mutableListOf<String>()
        val reasons = mutableListOf<String?>()
        val rows: List<IndependentSettingRow<String, Target>> get() {
            val first = IndependentSettingRow("first", "First", listOf("off", " On "), null, Target.FIRST, null)
            val second = IndependentSettingRow("second", "Second", listOf("off", "on"), "on",
                Target.SECOND.takeIf { secondAvailable }, "Host refusal".takeUnless { secondAvailable })
            return if (reversed) listOf(second, first) else listOf(first, second)
        }
    }

    private fun withPanel(body: (Fixture, ActivityScenario<GalleryOpeningTestActivity>) -> Unit) {
        ActivityScenario.launch(GalleryOpeningTestActivity::class.java).use { scenario ->
            val fixture = Fixture()
            scenario.onActivity { activity ->
                activity.setContent {
                    if (fixture.visible) MonitorIndependentSettingsPanel(fixture.rows, fixture.enabled,
                        { fixture.sourceCurrent },
                        { request, option -> fixture.requests += request; fixture.options += option },
                        { id, reason -> fixture.refusals += id; fixture.reasons += reason })
                }
            }
            option("first", 0)
            body(fixture, scenario)
        }
    }

    private fun click(node: AccessibilityNodeInfo) {
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private fun option(row: String, index: Int) = awaitNode {
        tag(it) == "monitor.independentSettings.$row.option.$index"
    }

    private fun titles(): List<String> = nodes().filter { tag(it)?.endsWith(".title") == true }
        .sortedBy { it.boundsInScreenTop() }.map { it.text?.toString() ?: it.contentDescription.toString() }

    private fun AccessibilityNodeInfo.boundsInScreenTop(): Int = android.graphics.Rect().also { getBoundsInScreen(it) }.top

    private fun tag(node: AccessibilityNodeInfo): String? {
        val key = "androidx.compose.ui.semantics.testTag"
        if (key in node.availableExtraData) node.refreshWithExtraData(key, Bundle())
        return node.extras.getCharSequence(key)?.toString()
    }

    private fun awaitNode(matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        val end = SystemClock.uptimeMillis() + 5_000
        do {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            nodes().firstOrNull { it.isVisibleToUser && matches(it) }?.let { return it }
            SystemClock.sleep(16)
        } while (SystemClock.uptimeMillis() < end)
        val actual = nodes().joinToString("\n") { node ->
            "package=${node.packageName} text=${node.text} description=${node.contentDescription} " +
                "tag=${tag(node)} resource=${node.viewIdResourceName} visible=${node.isVisibleToUser} " +
                "clickable=${node.isClickable} extras=${node.availableExtraData}"
        }
        throw AssertionError("The actual panel must expose the requested native element. Actual native tree:\n$actual")
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
