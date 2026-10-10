package com.opencapture.opencine.appkit

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState

/** One mounted transition owner; callbacks adapt existing typed presentation and native inputs. */
@Composable
public fun MonitorInteractionEffect(
    context: MonitorInteractionContext,
    onTransition: (MonitorInteractionTransition) -> Unit,
): Unit {
    val owner = remember { MonitorInteractionLifecycle() }
    val currentTransition = rememberUpdatedState(onTransition)
    LaunchedEffect(context) { currentTransition.value(owner.update(context)) }
    DisposableEffect(owner) {
        onDispose { currentTransition.value(owner.close()) }
    }
}
