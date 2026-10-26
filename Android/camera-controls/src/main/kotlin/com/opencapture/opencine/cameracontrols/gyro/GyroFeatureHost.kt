package com.opencapture.opencine.cameracontrols.gyro

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.appkit.MediaShare
import com.opencapture.opencine.gyro.GyroArmingStep
import com.opencapture.opencine.gyro.GyroCaptureCoordinator
import com.opencapture.opencine.gyro.GyroCaptureState
import com.opencapture.opencine.gyro.GyroNotice
import com.opencapture.opencine.gyro.GyroRingState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** How long a notice banner stays before the host clears it. */
private const val GYRO_NOTICE_MILLIS = 4_000L

/**
 * The whole gyro feature around a host screen (Swift twin: `View.gyroFeature(_:)`): wrap the
 * monitor in it once and every gyro presentation follows [coordinator]'s state. In priority order
 * it shows the arming setup (`setupSteps` non-empty) or the ring calibration (`ring` non-null) as a
 * full-screen dialog, then the logs screen (`logsPresented`) in the same dialog, then the
 * post-take drift prompt as a bottom sheet. Over the topmost layer it shows the current notice for
 * 4 s (then [GyroCaptureCoordinator.clearNotice]), announced by TalkBack. Each new drift
 * confirmation gives one haptic and announces the pill's MOUNT MOVED. Sharing from the logs builds
 * [share]'s chooser off the main thread and starts it; a share that cannot start raises the share
 * notice.
 *
 * The host still owns the pill and the settings: the pill's tap and the settings Open row call
 * [GyroCaptureCoordinator.presentLogs], the settings calibrate row calls
 * [GyroCaptureCoordinator.beginCalibration].
 */
@Composable
public fun GyroFeatureHost(
    coordinator: GyroCaptureCoordinator,
    share: MediaShare,
    content: @Composable () -> Unit,
) {
    val state by coordinator.state.collectAsState()
    val context = LocalContext.current
    val view = LocalView.current
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val presentation = gyroFullScreenPresentation(state)

    LaunchedEffect(state.notice) {
        val notice = state.notice ?: return@LaunchedEffect
        gyroAnnounce(view, GyroCopy.notice(notice))
        delay(GYRO_NOTICE_MILLIS)
        coordinator.clearNotice()
    }

    var seenHapticToken by remember { mutableStateOf<Int?>(null) }
    LaunchedEffect(state.driftHapticToken) {
        val previous = seenHapticToken
        seenHapticToken = state.driftHapticToken
        if (previous != null && state.driftHapticToken > previous) {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            gyroAnnounce(view, GyroCopy.pillMountMoved)
        }
    }

    Box(Modifier.fillMaxSize()) {
        content()
        if (presentation == null) GyroNoticeBanner(state.notice)
    }

    if (presentation != null) {
        Dialog(
            onDismissRequest = { gyroDismiss(coordinator, presentation) },
            properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
        ) {
            Box(Modifier.fillMaxSize().background(MonitorPalette.background)) {
                when (presentation) {
                    is GyroFullScreen.Setup -> GyroSetupSheet(
                        step = presentation.step,
                        ring = presentation.ring,
                        actions = gyroSetupActions(coordinator),
                        ringEventToken = state.ringEventToken,
                    )
                    is GyroFullScreen.Calibration -> GyroRingCalibrationScreen(
                        state = presentation.ring,
                        canUseLast = false,
                        eventToken = state.ringEventToken,
                        actions = GyroSetupActions(
                            getStarted = coordinator::startRing,
                            cancel = coordinator::cancelCalibration,
                            done = coordinator::finishCalibration,
                        ),
                    )
                    GyroFullScreen.Logs -> GyroLogsScreen(
                        entries = state.logs,
                        tipVisible = state.tipVisible,
                        gyroEnabled = state.enabled,
                        nowMillis = remember(state.logs) { System.currentTimeMillis() },
                        actions = GyroLogsActions(
                            share = { ids -> gyroShare(scope, context, coordinator, share, ids) },
                            delete = coordinator::delete,
                            dismissTip = coordinator::dismissTip,
                            turnOnGyro = { coordinator.setEnabled(true) },
                            close = coordinator::dismissLogs,
                        ),
                    )
                }
                GyroNoticeBanner(state.notice)
            }
        }
    } else if (state.driftPromptPresented) {
        GyroDriftSheet(
            onRecalibrate = coordinator::recalibrateAfterDrift,
            onNotNow = coordinator::dismissDriftPrompt,
        )
    }
}

/** What the full-screen gyro dialog shows, if anything. */
internal sealed interface GyroFullScreen {
    /** The arming setup at [step]; [ring] once the calibration step has started its ring. */
    data class Setup(val step: GyroArmingStep, val ring: GyroRingState?) : GyroFullScreen

    /** A ring calibration opened outside setup (settings, the drift prompt). */
    data class Calibration(val ring: GyroRingState) : GyroFullScreen

    /** The logs screen. */
    data object Logs : GyroFullScreen
}

/** The full-screen presentation for [state] in priority order: setup, calibration, logs. */
internal fun gyroFullScreenPresentation(state: GyroCaptureState): GyroFullScreen? {
    state.setupSteps.firstOrNull()?.let { return GyroFullScreen.Setup(it, state.ring) }
    state.ring?.let { return GyroFullScreen.Calibration(it) }
    return if (state.logsPresented) GyroFullScreen.Logs else null
}

/**
 * The setup sheet's actions. The calibration step shows its intro before any ring exists, so Get
 * started opens the ring first and Cancel skips calibration for this session; once the ring runs
 * both act on it.
 */
private fun gyroSetupActions(coordinator: GyroCaptureCoordinator): GyroSetupActions = GyroSetupActions(
    turnOff = coordinator::setupTurnOffStabilization,
    keepOn = coordinator::setupKeepStabilization,
    getStarted = {
        if (coordinator.state.value.ring == null) coordinator.beginCalibration()
        coordinator.startRing()
    },
    useLast = coordinator::setupUseLastCalibration,
    cancel = {
        if (coordinator.state.value.ring == null) {
            coordinator.setupSkipCalibration()
        } else {
            coordinator.cancelCalibration()
        }
    },
    done = coordinator::finishCalibration,
)

/** Back or a dismiss request on the dialog: the same choice the screen's own back offers. */
private fun gyroDismiss(coordinator: GyroCaptureCoordinator, presentation: GyroFullScreen) {
    when (presentation) {
        is GyroFullScreen.Setup -> when (presentation.step) {
            is GyroArmingStep.Stabilization -> coordinator.setupKeepStabilization()
            is GyroArmingStep.Calibration -> gyroSetupActions(coordinator).cancel()
        }
        is GyroFullScreen.Calibration -> coordinator.cancelCalibration()
        GyroFullScreen.Logs -> coordinator.dismissLogs()
    }
}

/**
 * Shares the finished logs [ids]: the coordinator's files and the chooser are built off the main
 * thread, the chooser starts on the main thread. A failure to build or start it raises the share
 * notice; an empty file list was already reported by the coordinator.
 */
private fun gyroShare(
    scope: CoroutineScope,
    context: Context,
    coordinator: GyroCaptureCoordinator,
    share: MediaShare,
    ids: List<String>,
) {
    scope.launch {
        val built = withContext(Dispatchers.IO) {
            runCatching {
                val files = coordinator.shareFiles(ids)
                if (files.isEmpty()) {
                    GyroShareOutcome.Nothing
                } else {
                    val intent = share.chooserIntent(context, files, { "text/plain" })
                    if (intent == null) GyroShareOutcome.Failed else GyroShareOutcome.Ready(intent)
                }
            }.getOrElse { error ->
                if (error is CancellationException) throw error
                GyroShareOutcome.Failed
            }
        }
        when (built) {
            is GyroShareOutcome.Ready -> try {
                context.startActivity(built.intent)
            } catch (_: ActivityNotFoundException) {
                coordinator.reportShareFailed()
            } catch (_: SecurityException) {
                coordinator.reportShareFailed()
            }
            GyroShareOutcome.Failed -> coordinator.reportShareFailed()
            GyroShareOutcome.Nothing -> Unit
        }
    }
}

/** The result of building a share. */
private sealed interface GyroShareOutcome {
    /** The chooser to start. */
    data class Ready(val intent: Intent) : GyroShareOutcome

    /** The chooser could not be built. */
    data object Failed : GyroShareOutcome

    /** No files; the coordinator already raised its notice when that was a failure. */
    data object Nothing : GyroShareOutcome
}

/** The current notice as a banner at the top of the layer it sits in; the host announces it once. */
@Composable
private fun BoxScope.GyroNoticeBanner(notice: GyroNotice?) {
    if (notice == null) return
    Box(
        Modifier
            .align(Alignment.TopCenter)
            .statusBarsPadding()
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .widthIn(max = 520.dp)
            .fillMaxWidth()
            .background(MonitorPalette.surface, RoundedCornerShape(12.dp))
            .semantics(mergeDescendants = true) { testTagsAsResourceId = true }
            .testTag("gyro.notice")
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(
            text = GyroCopy.notice(notice),
            modifier = Modifier.fillMaxWidth(),
            color = MonitorPalette.text,
            textAlign = TextAlign.Center,
            style = MonitorTypography.text(15f),
        )
    }
}
