package com.opencapture.opencine.appkit

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.MonitorBlurCapability

/**
 * When a live backdrop producer may sample: [enabled] by the shell, a device that sustains the
 * sampled blur ([MonitorBlurCapability]), a hardware-accelerated attached window, and a resumed
 * screen. [setActive] hears every change and false on disposal; the producer owns frames.
 */
@Composable
public fun MonitorBackdropActivation(enabled: Boolean, setActive: (Boolean) -> Unit) {
    val context = LocalContext.current
    val view = LocalView.current
    val activate by rememberUpdatedState(setActive)
    val capable = remember(context) {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memory = ActivityManager.MemoryInfo().also(manager::getMemoryInfo)
        MonitorBlurCapability.isSupported(Build.VERSION.SDK_INT, isLowRamDevice = manager.isLowRamDevice,
            totalRamBytes = memory.totalMem)
    }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(enabled, capable, view, lifecycle) {
        fun update() = activate(enabled && capable && view.isHardwareAccelerated &&
            lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        val attachment = object : View.OnAttachStateChangeListener {
            override fun onViewAttachedToWindow(view: View) = update()
            override fun onViewDetachedFromWindow(view: View) = activate(false)
        }
        view.addOnAttachStateChangeListener(attachment)
        val observer = LifecycleEventObserver { _, _ -> update() }
        lifecycle.addObserver(observer)
        update()
        onDispose {
            view.removeOnAttachStateChangeListener(attachment)
            lifecycle.removeObserver(observer)
            activate(false)
        }
    }
}
