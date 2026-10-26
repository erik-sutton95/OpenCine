package com.opencapture.opencine.cameracontrols.gyro

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography

// The text roles shared by every gyro screen: the gray overline above a title, the title itself and
// the supporting body line. The fit-the-ring calibration screens and the logs and take screens use
// the same sizes, colors and alignment so the screens read as one product.

/** The 12 sp letter-spaced gray line above a title. */
@Composable
internal fun GyroOverline(text: String, textAlign: TextAlign, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        modifier = modifier.fillMaxWidth(),
        color = GyroPalette.overline,
        textAlign = textAlign,
        style = MonitorTypography.text(12f).copy(letterSpacing = 0.8.sp),
    )
}

/** A screen title, marked as a heading for TalkBack. */
@Composable
internal fun GyroTitle(text: String, textAlign: TextAlign, modifier: Modifier = Modifier) {
    Text(
        text = text,
        modifier = modifier.fillMaxWidth().semantics { heading() },
        color = MonitorPalette.text,
        textAlign = textAlign,
        style = MonitorTypography.text(22f, FontWeight.SemiBold),
    )
}

/** Supporting copy under a title. */
@Composable
internal fun GyroBody(text: String, textAlign: TextAlign, modifier: Modifier = Modifier) {
    Text(
        text = text,
        modifier = modifier.fillMaxWidth(),
        color = GyroPalette.body,
        textAlign = textAlign,
        style = MonitorTypography.text(15f),
    )
}
