package com.opencapture.opencine.cameracontrols.gyro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorLinkHealth
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.gyro.GyroLogEntry
import com.opencapture.opencine.gyro.GyroTakeStatus

/**
 * One finished take's page: a status glyph, the verdict as the title, the camera with the length and
 * the mount calibration, the one Share log primary (disabled until the take can be shared) and the
 * Details section with the numbers. The logs screen hosts the same body in its landscape pane.
 *
 * Swift twin: `GyroTakeView`.
 */
@Composable
public fun GyroTakeScreen(
    entry: GyroLogEntry,
    onShare: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxSize()
            .background(MonitorPalette.background)
            .semantics { testTagsAsResourceId = true }
            .systemBarsPadding(),
    ) {
        GyroTakeBody(
            entry = entry,
            onShare = onShare,
            showShare = true,
            modifier = Modifier.fillMaxSize(),
        )
    }
}

/**
 * The take page's content without window insets, so the logs screen's portrait page and landscape
 * pane can place it themselves. [showShare] false keeps the one primary of Select mode on screen.
 */
@Composable
internal fun GyroTakeBody(
    entry: GyroLogEntry,
    onShare: () -> Unit,
    showShare: Boolean,
    modifier: Modifier = Modifier,
) {
    val status = entry.status
    Column(
        modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        TakeStatusVisual(status)
        Column(
            Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            GyroTitle(text = GyroCopy.verdict(status), textAlign = TextAlign.Center)
            GyroBody(text = takeSubtitle(entry), textAlign = TextAlign.Center)
        }
        if (showShare) {
            GyroPrimaryButton(
                text = GyroCopy.shareLog,
                onClick = onShare,
                enabled = entry.canShare,
            )
        }
        TakeDetails(entry)
    }
}

/** The verdict's picture: accent check for Ready, amber triangle otherwise, red dot while recording. */
@Composable
private fun TakeStatusVisual(status: GyroTakeStatus) {
    val ink = when (status) {
        GyroTakeStatus.Ready -> MonitorPalette.accent
        GyroTakeStatus.Recording -> MonitorPalette.recording
        else -> MonitorLinkHealth.watch
    }
    Box(
        Modifier
            .size(120.dp)
            .testTag("gyro.visual")
            .semantics(mergeDescendants = true) {
                contentDescription = GyroCopy.verdict(status)
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .size(96.dp)
                .clip(CircleShape)
                .background(ink.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center,
        ) {
            when (status) {
                GyroTakeStatus.Ready -> MonitorIcon(
                    icon = MonitorIcon.CHECK,
                    contentDescription = null,
                    modifier = Modifier.size(44.dp),
                    tint = ink,
                )
                GyroTakeStatus.Recording -> Box(
                    Modifier.size(28.dp).clip(CircleShape).background(ink),
                )
                else -> MonitorIcon(
                    icon = MonitorIcon.TRIANGLE_ALERT,
                    contentDescription = null,
                    modifier = Modifier.size(44.dp),
                    tint = ink,
                )
            }
        }
    }
}

/** The Details section: Starts, Smoothness and Sample rate, omitting the rows with no value. */
@Composable
private fun TakeDetails(entry: GyroLogEntry) {
    val status = entry.status
    val rows = buildList {
        entry.approximateStartOffset?.let {
            add(GyroCopy.startsLabel to GyroCopy.startOffset(it))
        }
        add(GyroCopy.smoothnessLabel to GyroCopy.smoothness(status))
        entry.measuredRate?.let {
            add(GyroCopy.sampleRateLabel to GyroCopy.sampleRate(it))
        }
    }
    Column(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        GyroOverline(
            text = GyroCopy.details,
            textAlign = TextAlign.Start,
            modifier = Modifier.padding(start = 2.dp, bottom = 2.dp),
        )
        rows.forEachIndexed { index, row ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 9.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = row.first,
                    color = GyroPalette.overline,
                    style = MonitorTypography.text(14f),
                )
                Text(
                    text = row.second,
                    color = MonitorPalette.text,
                    style = MonitorTypography.text(14f, FontWeight.Medium),
                )
            }
            if (index < rows.lastIndex) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(MonitorPalette.border))
            }
        }
    }
}

/** Camera, length and the calibration state, for example "camera · 0:48 · calibrated mount". */
private fun takeSubtitle(entry: GyroLogEntry): String {
    val parts = mutableListOf(entry.cameraLabel)
    entry.durationSeconds?.let { parts += GyroCopy.length(it) }
    parts += if (entry.isCalibrated) GyroCopy.calibratedMount else GyroCopy.notCalibrated
    return parts.joinToString(GyroCopy.separator)
}
