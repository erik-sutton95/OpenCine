package com.opencapture.opencine.cameracontrols.gyro

import android.view.View
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.gyro.GyroCalibrationInvalidation
import com.opencapture.opencine.gyro.GyroRingEvent
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState
import kotlinx.coroutines.delay
import kotlin.math.roundToInt

/**
 * The fill-the-ring calibration screens: intro, posing, retry, invalidated and complete. The host
 * owns the calibration and feeds [state]; [announcer] speaks a short phrase (the view's
 * accessibility announcer by default) and a capture also fires a long-press haptic.
 *
 * [eventToken] is `GyroCaptureState.ringEventToken`: when given, the haptic and announcement fire
 * once per token change, so a conflated state that skipped the event reply still announces it
 * and a recreated screen does not replay it. Without it (standalone use) they key on [state].
 */
@Composable
public fun GyroRingCalibrationScreen(
    state: GyroRingState,
    canUseLast: Boolean,
    actions: GyroSetupActions,
    modifier: Modifier = Modifier,
    eventToken: Int? = null,
    announcer: ((String) -> Unit)? = null,
) {
    val view = LocalView.current
    val announce: (String) -> Unit = announcer ?: { text -> gyroAnnounce(view, text) }
    val haptics = LocalHapticFeedback.current
    var flash by remember { mutableStateOf(false) }
    var retryVisible by remember { mutableStateOf(false) }
    var holdThreshold by remember { mutableIntStateOf(0) }

    var handledToken by rememberSaveable { mutableIntStateOf(eventToken ?: 0) }
    LaunchedEffect(eventToken ?: state) {
        val event =
            if (eventToken == null) {
                state.event
            } else {
                if (eventToken == handledToken) return@LaunchedEffect
                handledToken = eventToken
                gyroRingEventFor(state)
            }
        when (event) {
            GyroRingEvent.STEP_CAPTURED -> {
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                announce(GyroCopy.stepDoneA11y(state.completedSteps))
                flash = true
            }
            GyroRingEvent.VERIFICATION_FAILED -> retryVisible = true
            GyroRingEvent.COMPLETED -> announce(GyroCopy.completeTitle)
            null -> Unit
        }
    }
    LaunchedEffect(flash) {
        if (flash) {
            delay(600)
            flash = false
        }
    }
    LaunchedEffect(retryVisible) {
        if (retryVisible) {
            delay(2_000)
            retryVisible = false
        }
    }
    LaunchedEffect(state.step) { holdThreshold = 0 }
    LaunchedEffect(state.phase, state.step, state.inZone, state.hold) {
        val hold = state.hold
        if (state.phase == GyroRingPhase.POSING && state.inZone == true && hold != null) {
            gyroHoldAnnouncement(holdThreshold, hold)?.let { threshold ->
                holdThreshold = threshold
                announce(GyroCopy.holdProgressA11y(threshold))
            }
        }
    }

    val stateStep = state.step
    val poseStep: Int? = when {
        stateStep != null -> stateStep
        state.phase == GyroRingPhase.RETRYING -> 0
        else -> null
    }
    val complete = state.phase == GyroRingPhase.COMPLETE
    val baseModel = gyroRingModel(state)
    val ringModel = if (flash && !baseModel.checkmark) baseModel.copy(checkmark = true) else baseModel
    val a11yHold =
        if (state.phase == GyroRingPhase.POSING && state.inZone == true) state.hold else null
    val ringLabel = when {
        poseStep != null -> GyroCopy.step(poseStep)
        complete -> GyroCopy.completeTitle
        state.phase == GyroRingPhase.INVALIDATED ->
            state.invalidation?.let(GyroCopy::invalidation) ?: GyroCopy.calibrateTitle
        else -> GyroCopy.calibrateTitle
    }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(MonitorPalette.background)
            .semantics { testTagsAsResourceId = true },
    ) {
        val landscape = maxWidth > maxHeight
        val horizontal = if (landscape) Alignment.Start else Alignment.CenterHorizontally
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            if (!complete) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 44.dp)
                        .padding(horizontal = 12.dp),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    GyroLinkButton(
                        text = GyroCopy.cancel,
                        onClick = actions.cancel,
                        fillWidth = false,
                        tag = "gyro.cancel",
                    )
                }
            }
            GyroAdaptiveStack(
                modifier = Modifier.weight(1f),
                visual = {
                    Box(
                        Modifier
                            .fillMaxSize()
                            .testTag("gyro.visual")
                            .semantics(mergeDescendants = true) {
                                contentDescription = ringLabel
                                a11yHold?.let {
                                    stateDescription = GyroCopy.holdProgressA11y(
                                        (it * 100).roundToInt().coerceIn(0, 100),
                                    )
                                }
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        GyroRing(ringModel, Modifier.fillMaxSize())
                    }
                },
                header = {
                    RingHeader(
                        phase = state.phase,
                        poseStep = poseStep,
                        completedSteps = state.completedSteps,
                        invalidation = state.invalidation,
                        landscape = landscape,
                    )
                },
                footer = {
                    Column(
                        Modifier.fillMaxWidth(),
                        horizontalAlignment = horizontal,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        when (state.phase) {
                            GyroRingPhase.INTRO -> {
                                GyroPrimaryButton(
                                    text = GyroCopy.getStarted,
                                    onClick = actions.getStarted,
                                )
                                if (canUseLast) {
                                    GyroLinkButton(
                                        text = GyroCopy.useLastCalibration,
                                        onClick = actions.useLast,
                                        tag = "gyro.useLast",
                                    )
                                }
                            }
                            GyroRingPhase.COMPLETE, GyroRingPhase.INVALIDATED ->
                                GyroPrimaryButton(text = GyroCopy.done, onClick = actions.done)
                            GyroRingPhase.BLOCKED -> RingHint(
                                text = state.block?.let(GyroCopy::block) ?: GyroCopy.holdHint,
                                landscape = landscape,
                            )
                            GyroRingPhase.RETRYING -> RingHint(
                                text = GyroCopy.retry,
                                landscape = landscape,
                            )
                            GyroRingPhase.POSING -> RingHint(
                                text = if (retryVisible) GyroCopy.retry else GyroCopy.holdHint,
                                landscape = landscape,
                            )
                        }
                    }
                },
            )
        }
    }
}

/** Posts a TalkBack announcement through the host view; the feature host shares it. */
@Suppress("DEPRECATION")
internal fun gyroAnnounce(view: View, text: String) {
    view.announceForAccessibility(text)
}

/** The header copy for one ring phase: title, overline, progress dots and supporting line. */
@Composable
private fun RingHeader(
    phase: GyroRingPhase,
    poseStep: Int?,
    completedSteps: Int,
    invalidation: GyroCalibrationInvalidation?,
    landscape: Boolean,
) {
    val horizontal = if (landscape) Alignment.Start else Alignment.CenterHorizontally
    val textAlign = if (landscape) TextAlign.Start else TextAlign.Center
    Column(
        Modifier.fillMaxWidth(),
        horizontalAlignment = horizontal,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        when {
            poseStep != null -> {
                GyroOverline(GyroCopy.stepCounter(poseStep + 1), textAlign)
                GyroTitle(GyroCopy.step(poseStep), textAlign)
                GyroDots(completedSteps)
            }
            phase == GyroRingPhase.COMPLETE -> {
                GyroOverline(GyroCopy.phoneMount, textAlign)
                GyroTitle(GyroCopy.completeTitle, textAlign)
                GyroBody(GyroCopy.completeBody, textAlign)
            }
            phase == GyroRingPhase.INVALIDATED -> {
                GyroOverline(GyroCopy.phoneMount, textAlign)
                GyroTitle(
                    invalidation?.let(GyroCopy::invalidation) ?: GyroCopy.calibrateTitle,
                    textAlign,
                )
            }
            else -> {
                GyroOverline(GyroCopy.phoneMount, textAlign)
                GyroTitle(GyroCopy.calibrateTitle, textAlign)
                GyroBody(GyroCopy.calibrateBody, textAlign)
            }
        }
    }
}

/** The three progress dots, filled up to the captured steps and hidden from TalkBack. */
@Composable
private fun GyroDots(completedSteps: Int) {
    Row(
        Modifier.clearAndSetSemantics { },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        repeat(3) { index ->
            Box(
                Modifier
                    .size(7.dp)
                    .clip(CircleShape)
                    .background(
                        if (index < completedSteps) MonitorPalette.accent else GyroPalette.dotOff,
                    ),
            )
        }
    }
}

/** The one footer line: the hold hint, the retry line or the block reason. */
@Composable
private fun RingHint(text: String, landscape: Boolean) {
    Text(
        text = text,
        modifier = Modifier.fillMaxWidth().testTag("gyro.hint"),
        color = GyroPalette.hint,
        textAlign = if (landscape) TextAlign.Start else TextAlign.Center,
        style = MonitorTypography.text(14f),
    )
}

/**
 * The event a new ring token stands for: the reply's own event, or, when a conflated state has
 * already moved past that reply, the one its phase implies (complete, a reset to zero poses after
 * a failed verification, otherwise a captured pose).
 */
internal fun gyroRingEventFor(state: GyroRingState): GyroRingEvent =
    state.event ?: when {
        state.phase == GyroRingPhase.COMPLETE -> GyroRingEvent.COMPLETED
        state.completedSteps == 0 -> GyroRingEvent.VERIFICATION_FAILED
        else -> GyroRingEvent.STEP_CAPTURED
    }
