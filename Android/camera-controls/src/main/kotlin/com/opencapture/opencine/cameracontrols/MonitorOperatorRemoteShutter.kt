package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.currentStateAsState
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorRemoteShutter
import com.opencapture.opencine.appkit.MonitorRemoteShutterCommand
import com.opencapture.opencine.appkit.monitorRemoteShutterRecordingTarget
import com.opencapture.opencine.appkit.monitorRemoteShutterShouldArm

/**
 * The activity's remote shutter owner (A2-32). An app that offers the remote shutter creates one
 * [MonitorRemoteShutter] per activity, routes its key events to it, closes it at teardown and provides it
 * here; the shared live surface arms it. Absent, no surface claims the media keys.
 */
public val LocalMonitorRemoteShutter: ProvidableCompositionLocal<MonitorRemoteShutter?> =
    staticCompositionLocalOf { null }

/**
 * Arms [LocalMonitorRemoteShutter] while this live monitor is in front and a press may record: the
 * operator's choice, a connected video camera, a resumed app, and no record command or confirmation
 * already open. Each accepted press records through [control], skipping record confirmation like the
 * watch: an unseen phone dialog would strand the take.
 */
@Composable
internal fun MonitorOperatorRemoteShutterArming(
    enabled: Boolean,
    monitorIsFront: Boolean,
    photo: Boolean,
    recordConfirming: Boolean,
    control: MonitorControlModel,
) {
    val shutter = LocalMonitorRemoteShutter.current ?: return
    val state by control.state.collectAsState()
    val lifecycle by LocalLifecycleOwner.current.lifecycle.currentStateAsState()
    val armed = monitorRemoteShutterShouldArm(
        enabled = enabled && !photo,
        monitorIsFront = monitorIsFront,
        cameraConnected = state.snapshot != null,
        recordCommandPending = state.recordPending,
        applicationResumed = lifecycle.isAtLeast(Lifecycle.State.RESUMED),
        recordConfirmationPending = recordConfirming,
        cameraControlPending = false,
    )
    val latest by rememberUpdatedState(control)
    DisposableEffect(shutter, armed) {
        if (armed) shutter.arm { command -> latest.recordFromRemoteShutter(command) } else shutter.disarm()
        onDispose { shutter.disarm() }
    }
}

/** One remote press: the recording state it asks for, sent without the phone-side confirmation. */
internal fun MonitorControlModel.recordFromRemoteShutter(command: MonitorRemoteShutterCommand): Boolean {
    val recording = isRecording ?: return false
    val target = monitorRemoteShutterRecordingTarget(command, recording) ?: return false
    record(target)
    return true
}
