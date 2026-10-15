package com.opencapture.opencine.appuitesting

import android.app.Activity
import com.opencapture.monitorui.MonitorCapabilities

/**
 * The app under test, declared once in its androidTest source set (Swift twin: the bundle's
 * principal class). [activity] is the app's real launcher entry; scenarios launch it with a
 * `ReviewLaunch` and never mount a composable.
 */
public interface ConformanceApp {
    public val activity: Class<out Activity>
    public val profile: ConformanceProfile
}

/**
 * What the app under test can do. Scenarios derive their expectations from it and never branch on
 * the app: a capability the camera lacks is a skip, anything the profile admits must pass.
 */
public data class ConformanceProfile(
    /** Names evidence only. */
    val app: String,
    /** The value the app's live UI renders from for its review body. */
    val capabilities: MonitorCapabilities,
)
