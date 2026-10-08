package com.opencapture.monitorui

import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.findViewTreeLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Static, bounded UI material input; never reads a surface, source service or decoder. */
@Composable
fun rememberMonitorPhotoBackdrop(bitmap: Bitmap?, identity: Any): MonitorBackdropSource {
    val source = remember { MonitorBackdropSource() }
    val view = LocalView.current
    val lifecycle = view.findViewTreeLifecycleOwner()?.lifecycle
    var resumed by remember { mutableStateOf(false) }
    DisposableEffect(source, lifecycle) {
        fun update() {
            resumed = lifecycle?.currentState?.isAtLeast(Lifecycle.State.RESUMED) == true
            if (!resumed) source.image = null
        }
        val observer = LifecycleEventObserver { _, _ -> update() }
        lifecycle?.addObserver(observer); update()
        onDispose { lifecycle?.removeObserver(observer); source.image = null }
    }
    LaunchedEffect(bitmap, identity, resumed) {
        source.image = null
        if (bitmap != null && resumed) {
            source.image = withContext(Dispatchers.Default) {
                val scale = minOf(1f, 213f / bitmap.width, 120f / bitmap.height)
                Bitmap.createScaledBitmap(bitmap, (bitmap.width * scale).toInt().coerceAtLeast(1),
                    (bitmap.height * scale).toInt().coerceAtLeast(1), true)
            }
        }
    }
    return source
}
