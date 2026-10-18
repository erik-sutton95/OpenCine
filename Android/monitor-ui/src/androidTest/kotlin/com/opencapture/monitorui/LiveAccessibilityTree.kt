package com.opencapture.monitorui

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.os.Build
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import kotlin.test.assertTrue

/**
 * What TalkBack reads from every interactive window (the shared playback chrome is a popup window
 * of its own), read live through UiAutomation. Instrumented tests only.
 */
internal object LiveAccessibilityTree {
    /** The first node whose text or content description is [label], within [timeoutMs]. */
    fun await(label: String, timeoutMs: Long = 5_000): AccessibilityNodeInfo? =
        awaitFirst(timeoutMs) { it.text?.toString() == label || it.contentDescription?.toString() == label }

    /** Whether no node reads [label] any more, within [timeoutMs]. */
    fun awaitGone(label: String, timeoutMs: Long = 5_000): Boolean {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        do {
            if (await(label, 0) == null) return true
            Thread.yield()
        } while (SystemClock.uptimeMillis() < deadline)
        return false
    }

    /** Activates the clickable control that carries [label], as a screen reader does. */
    fun click(label: String) {
        val found = requireNotNull(await(label)) { "Actual shared playback action did not mount: $label" }
        // A text label sits inside its merged clickable control; act on that control.
        val node = generateSequence(found) { it.parent }.firstOrNull { it.isClickable }
            ?: error("Actual shared playback action has no clickable control: $label")
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK), "Actual accessibility input refused: $label")
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private fun awaitFirst(timeoutMs: Long, matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val automation = windowsAutomation()
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        do {
            instrumentation.waitForIdleSync()
            // Compose reports no change events to UiAutomation alone, so cached nodes go stale; read the live tree.
            if (Build.VERSION.SDK_INT >= 34) automation.clearCache()
            for (window in automation.windows) {
                window.root?.let { root -> find(root, matches)?.let { return it } }
            }
            Thread.yield()
        } while (SystemClock.uptimeMillis() < deadline)
        return null
    }

    /** UiAutomation lists no windows until it opts in to interactive windows. */
    private fun windowsAutomation(): UiAutomation {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val info = automation.serviceInfo
        if ((info.flags and AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS) == 0) {
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            automation.serviceInfo = info
        }
        return automation
    }

    private fun find(node: AccessibilityNodeInfo, matches: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        if (matches(node)) return node
        for (index in 0 until node.childCount) node.getChild(index)?.let { child ->
            find(child, matches)?.let { return it }
        }
        return null
    }
}
