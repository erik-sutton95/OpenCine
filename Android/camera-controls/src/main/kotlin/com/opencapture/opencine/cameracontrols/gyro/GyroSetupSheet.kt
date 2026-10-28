package com.opencapture.opencine.cameracontrols.gyro

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.gyro.GyroArmingStep
import com.opencapture.opencine.gyro.GyroRingPhase
import com.opencapture.opencine.gyro.GyroRingState

/** What the arming sheet and the calibration screens can ask of the host. */
public class GyroSetupActions(
    /** Turn the camera's stabilization off and carry on arming. */
    public val turnOff: () -> Unit = {},
    /** Keep stabilization on; the gyro pill will warn until it is off. */
    public val keepOn: () -> Unit = {},
    /** Start the ring calibration. */
    public val getStarted: () -> Unit = {},
    /** Skip calibration and reuse the saved mount calibration. */
    public val useLast: () -> Unit = {},
    /** Leave the setup sheet without changing the camera. */
    public val cancel: () -> Unit = {},
    /** Close the finished calibration. */
    public val done: () -> Unit = {},
)

/**
 * The arming sheet: the stabilization step, then the calibration step. Values and actions only;
 * the host decides which step to show and feeds the ring state. Back acts as "Keep it on" on the
 * stabilization step and as cancel on the calibration step. [ringEventToken] is forwarded to
 * [GyroRingCalibrationScreen] (`GyroCaptureState.ringEventToken`).
 */
@Composable
public fun GyroSetupSheet(
    step: GyroArmingStep,
    ring: GyroRingState?,
    actions: GyroSetupActions,
    modifier: Modifier = Modifier,
    ringEventToken: Int? = null,
) {
    when (step) {
        is GyroArmingStep.Stabilization -> {
            BackHandler { actions.keepOn() }
            StabilizationSheet(step.lensHasVRSwitch, actions, modifier)
        }
        is GyroArmingStep.Calibration -> {
            BackHandler { actions.cancel() }
            GyroRingCalibrationScreen(
                state = ring ?: introRingState(),
                canUseLast = step.hasSavedCalibration,
                actions = actions,
                modifier = modifier,
                eventToken = ringEventToken,
            )
        }
    }
}

/** The stabilization step: why IBIS matters, one primary "Turn off IBIS" and a keep choice. */
@Composable
private fun StabilizationSheet(
    lensHasVRSwitch: Boolean?,
    actions: GyroSetupActions,
    modifier: Modifier,
) {
    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(MonitorPalette.background)
            .semantics { testTagsAsResourceId = true },
    ) {
        val landscape = maxWidth > maxHeight
        val horizontal = if (landscape) Alignment.Start else Alignment.CenterHorizontally
        val textAlign = if (landscape) TextAlign.Start else TextAlign.Center
        // The spec gives this step two choices only (Turn off IBIS, Keep it on); no Cancel, so the
        // top bar keeps the calibration screens' height without a button.
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            Spacer(Modifier.fillMaxWidth().height(44.dp))
            GyroAdaptiveStack(
                modifier = Modifier.weight(1f),
                visual = { StabilizationVisual() },
                header = {
                    Column(
                        Modifier.fillMaxWidth(),
                        horizontalAlignment = horizontal,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            text = GyroCopy.ibisTitle,
                            modifier = Modifier.fillMaxWidth().semantics { heading() },
                            color = MonitorPalette.text,
                            textAlign = textAlign,
                            style = MonitorTypography.text(22f, FontWeight.SemiBold),
                        )
                        Text(
                            text = GyroCopy.ibisReason,
                            modifier = Modifier.fillMaxWidth(),
                            color = GyroPalette.body,
                            textAlign = textAlign,
                            style = MonitorTypography.text(15f),
                        )
                        if (lensHasVRSwitch == true) {
                            Text(
                                text = GyroCopy.ibisLens,
                                modifier = Modifier.fillMaxWidth().testTag("gyro.setup.lens"),
                                color = GyroPalette.body,
                                textAlign = textAlign,
                                style = MonitorTypography.text(15f),
                            )
                        }
                    }
                },
                footer = {
                    Column(
                        Modifier.fillMaxWidth(),
                        horizontalAlignment = horizontal,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        GyroPrimaryButton(
                            text = GyroCopy.ibisTurnOff,
                            onClick = actions.turnOff,
                            tag = "gyro.setup.turnOff",
                        )
                        GyroSecondaryButton(
                            text = GyroCopy.ibisKeep,
                            onClick = actions.keepOn,
                            tag = "gyro.setup.keepOn",
                        )
                    }
                },
            )
        }
    }
}

/** A camera glyph in the calibration ring with a gyro badge, the stabilization step's picture. */
@Composable
private fun StabilizationVisual() {
    Box(
        Modifier
            .fillMaxSize()
            .testTag("gyro.visual")
            .semantics(mergeDescendants = true) { contentDescription = GyroCopy.ibisTitle },
        contentAlignment = Alignment.Center,
    ) {
        GyroRing(
            model = GyroRingModel(litFraction = 0.0, dimmed = false, checkmark = false),
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            Modifier
                .align(Alignment.Center)
                .offset(x = 46.dp, y = 40.dp)
                .size(34.dp)
                .clip(CircleShape)
                .background(MonitorPalette.surface)
                .border(1.dp, MonitorPalette.accent.copy(alpha = 0.45f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            MonitorIcon(
                icon = MonitorIcon.AUDIO_WAVEFORM,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = MonitorPalette.accent,
            )
        }
    }
}

/** The intro ring state the calibration step shows before the host sends its first reply. */
private fun introRingState(): GyroRingState = GyroRingState(
    phase = GyroRingPhase.INTRO,
    step = null,
    inZone = null,
    hold = null,
    block = null,
    invalidation = null,
    completedSteps = 0,
    event = null,
    calibrationJSON = null,
)
