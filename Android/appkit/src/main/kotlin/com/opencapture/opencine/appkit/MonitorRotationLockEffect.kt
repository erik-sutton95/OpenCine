package com.opencapture.opencine.appkit

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext

/**
 * The live surface's side of the rotation hold: while [locked] the activity keeps its current
 * rotation (`SCREEN_ORIENTATION_LOCKED`, which holds reverse landscape and reverse portrait too);
 * unlocking or leaving the composition restores the request the activity had before.
 */
@Composable
public fun MonitorRotationLockEffect(locked: Boolean): Unit {
    val activity = LocalContext.current.monitorActivity() ?: return
    DisposableEffect(activity, locked) {
        val hold = MonitorRotationHold<Int>()
        // A request left LOCKED (an activity recreated while held) restores to the manifest's.
        val before = activity.requestedOrientation.takeUnless { it == ActivityInfo.SCREEN_ORIENTATION_LOCKED }
            ?: activity.declaredOrientation()
        if (hold.update(locked, before)) activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LOCKED
        onDispose {
            val restore = hold.held
            if (hold.update(false, null) && restore != null) activity.requestedOrientation = restore
        }
    }
}

private tailrec fun Context.monitorActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.monitorActivity()
    else -> null
}

private fun Activity.declaredOrientation(): Int = runCatching {
    packageManager.getActivityInfo(componentName, 0).screenOrientation
}.getOrDefault(ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED)
