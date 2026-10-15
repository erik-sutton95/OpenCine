package com.opencapture.opencine.systemhints

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The listener's setting is what keeps the tutorial away: with the acknowledgement removed the
 * tutorial covers an immersive window, and with [SystemHints.suppress] it never does. Runs on an
 * emulator or test device; it changes only the setting the tutorial itself writes and leaves it
 * acknowledged.
 */
@RunWith(AndroidJUnit4::class)
class SystemHintsTest {
    private val automation: UiAutomation = InstrumentationRegistry.getInstrumentation().uiAutomation.also {
        it.serviceInfo = it.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS }
    }

    @After
    fun leaveTheTutorialAcknowledged() {
        SystemHints.suppress(automation)
    }

    @Test
    fun theListenerAcknowledgedTheTutorialBeforeTheFirstTest() {
        assertTrue(SystemHintsListener.ran, "The manifest-declared run listener must run before the first test")
        assertEquals(SystemHints.CONFIRMED, SystemHints.shell(automation, "settings get secure ${SystemHints.IMMERSIVE_CONFIRMATIONS}").trim())
    }

    @Test
    fun suppressIsIdempotent() {
        SystemHints.suppress(automation)
        SystemHints.suppress(automation)
        assertEquals(SystemHints.CONFIRMED, SystemHints.shell(automation, "settings get secure ${SystemHints.IMMERSIVE_CONFIRMATIONS}").trim())
    }

    @Test
    fun withoutTheAcknowledgementTheTutorialCoversAnImmersiveWindowAndWithItItDoesNot() {
        SystemHints.shell(automation, "settings delete secure ${SystemHints.IMMERSIVE_CONFIRMATIONS}")
        val shownAfter = ActivityScenario.launch(ImmersiveTestActivity::class.java).use {
            checkNotNull(tutorialShownWithin(30_000)) { "Control: the tutorial must cover an immersive window while unacknowledged" }
                .also { dismissTutorial() }
        }

        SystemHints.shell(automation, "settings delete secure ${SystemHints.IMMERSIVE_CONFIRMATIONS}")
        SystemHints.suppress(automation)
        // The control measured how late the tutorial comes on this device; wait well past that.
        val window = maxOf(5_000L, shownAfter * 3)
        val suppressed = ActivityScenario.launch(ImmersiveTestActivity::class.java).use { tutorialShownWithin(window) }
        assertEquals(null, suppressed, "The acknowledged tutorial must not appear (waited ${window}ms)")
    }

    /** Milliseconds until the tutorial showed, or null if it did not within [timeout]. */
    private fun tutorialShownWithin(timeout: Long): Long? {
        val start = SystemClock.uptimeMillis()
        while (SystemClock.uptimeMillis() - start < timeout) {
            if (tutorialNode("Viewing full screen") != null) return SystemClock.uptimeMillis() - start
            SystemClock.sleep(100)
        }
        return null
    }

    private fun dismissTutorial() {
        tutorialNode("Got it")?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    private fun tutorialNode(text: String): AccessibilityNodeInfo? =
        automation.windows.asSequence().mapNotNull { it.root }.plus(listOfNotNull(automation.rootInActiveWindow))
            .flatMap { it.findAccessibilityNodeInfosByText(text).asSequence() }
            .firstOrNull { it.isVisibleToUser }
}
