package com.opencapture.opencine.cameracontrols.gyro

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette

/** The sheet's corner radius, shared with the Monitor theme. */
private const val GYRO_DRIFT_SHEET_RADIUS_DP = 12f

/**
 * The post-take "mount moved" prompt (Swift twin: GyroDriftSheet): the title, the question, one
 * primary **Recalibrate** and a plain **Not now**, as a modal bottom sheet on the monitor surface.
 * Dismissing the sheet (a swipe down, a tap outside, Back) is the same as Not now.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
public fun GyroDriftSheet(onRecalibrate: () -> Unit, onNotNow: () -> Unit) {
    val shape = RoundedCornerShape(
        topStart = GYRO_DRIFT_SHEET_RADIUS_DP.dp,
        topEnd = GYRO_DRIFT_SHEET_RADIUS_DP.dp,
    )
    ModalBottomSheet(
        onDismissRequest = onNotNow,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = shape,
        containerColor = MonitorPalette.surface,
        contentColor = MonitorPalette.text,
    ) {
        GyroDriftSheetContent(onRecalibrate = onRecalibrate, onNotNow = onNotNow)
    }
}

/** The drift prompt's content without the sheet window, so it can be hosted and tested on its own. */
@Composable
internal fun GyroDriftSheetContent(
    onRecalibrate: () -> Unit,
    onNotNow: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxWidth()
            .background(MonitorPalette.surface, RoundedCornerShape(GYRO_DRIFT_SHEET_RADIUS_DP.dp))
            .semantics { testTagsAsResourceId = true }
            .padding(horizontal = 20.dp, vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(
            Modifier.widthIn(max = 480.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            GyroTitle(GyroCopy.driftTitle, TextAlign.Center)
            GyroBody(GyroCopy.driftQuestion, TextAlign.Center)
            Spacer(Modifier.height(8.dp))
            GyroPrimaryButton(text = GyroCopy.recalibrate, onClick = onRecalibrate, tag = "gyro.drift.recalibrate")
            GyroSecondaryButton(text = GyroCopy.notNow, onClick = onNotNow, tag = "gyro.drift.notNow")
        }
    }
}
