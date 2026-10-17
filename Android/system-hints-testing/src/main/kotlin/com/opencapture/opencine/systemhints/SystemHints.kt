package com.opencapture.opencine.systemhints

import android.app.UiAutomation
import android.os.ParcelFileDescriptor
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.runner.Description
import org.junit.runner.notification.RunListener

/**
 * Android's own first-run hints, which the system window manager draws over whatever app hides
 * its system bars. On a fresh emulator or device the "Viewing full screen" tutorial appears a few
 * seconds after the first immersive window (later under load) and holds the focus until someone
 * taps "Got it", so a test's lookup window can expire behind it. Android keeps the acknowledgement
 * in its typed secure setting [IMMERSIVE_CONFIRMATIONS]; writing the value the tutorial itself
 * writes is the same state an operator reaches by tapping "Got it" once.
 */
public object SystemHints {
    /** `Settings.Secure.IMMERSIVE_MODE_CONFIRMATIONS` (hidden in the SDK). */
    public const val IMMERSIVE_CONFIRMATIONS: String = "immersive_mode_confirmations"

    /** The value Android writes when the full screen tutorial is acknowledged for every package. */
    public const val CONFIRMED: String = "confirmed"

    /**
     * Marks the full screen tutorial acknowledged, through the instrumentation's shell identity
     * (no app permission), and checks that the device kept it. Idempotent.
     */
    public fun suppress(automation: UiAutomation = InstrumentationRegistry.getInstrumentation().uiAutomation) {
        if (shell(automation, "settings get secure $IMMERSIVE_CONFIRMATIONS").trim() == CONFIRMED) return
        shell(automation, "settings put secure $IMMERSIVE_CONFIRMATIONS $CONFIRMED")
        val stored = shell(automation, "settings get secure $IMMERSIVE_CONFIRMATIONS").trim()
        check(stored == CONFIRMED) { "The device did not keep $IMMERSIVE_CONFIRMATIONS=$CONFIRMED (read \"$stored\")" }
    }

    internal fun shell(automation: UiAutomation, command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command)).bufferedReader().use { it.readText() }
}

/**
 * Turns off Android's first-run hints once, before the first test of the run. This library's
 * manifest names it as the runner's `listener` argument, so every test APK that links the library
 * runs it, however the run is started.
 */
public class SystemHintsListener : RunListener() {
    override fun testRunStarted(description: Description?) {
        SystemHints.suppress()
        ran = true
    }

    public companion object {
        /** Whether a run listener of this process already turned the hints off (for the self-test). */
        @Volatile
        public var ran: Boolean = false
            private set
    }
}
