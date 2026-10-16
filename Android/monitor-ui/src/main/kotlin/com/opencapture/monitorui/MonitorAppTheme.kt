package com.opencapture.monitorui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ProvideTextStyle
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * The camera apps' Material colours. The accent is the brand's, read from [MonitorPalette.accent]
 * when used, so a brand installed at launch shows everywhere.
 */
object MonitorBrandColors {
    val accent: Color get() = MonitorPalette.accent
    val background: Color = MonitorPalette.background
    val surface: Color = MonitorPalette.surface
    val ink: Color = Color.White
    val darkText: Color = MonitorPalette.background
}

/** The camera apps' operator design tokens on top of [MonitorPalette]. */
object MonitorDesign {
    val background = MonitorPalette.background

    /**
     * Scope plate: black at 72%. Compose frame and Vulkan plot fill use this exact RGBA so
     * WAVE / PARADE / VECTOR don't read as a cutout.
     */
    val scopePlate = Color(20 / 255f, 20 / 255f, 20 / 255f, 0.72f)
    val surface = MonitorPalette.surface
    val text = Color.White
    val muted = MonitorPalette.muted
    val faint = Color(94 / 255f, 98 / 255f, 98 / 255f)
    val accent get() = MonitorPalette.accent
    val good = Color(0.18f, 0.78f, 0.42f)
    val rec = MonitorPalette.recording
    val amber = Color(0.914f, 0.674f, 0.208f)
    val hairlineStrong = Color.White.copy(alpha = 0.10f)
    val hairline = MonitorPalette.border
    val feedWell = Color.Black

    const val CORNER_RADIUS_DP = 12f
}

/** One optical family for every surface. Numeric readouts use tabular Sora figures. */
object MonitorType {
    fun display(size: Float, weight: FontWeight = FontWeight.SemiBold) = MonitorTypography.text(size, weight)

    fun title(size: Float, weight: FontWeight = FontWeight.SemiBold) = display(size, weight)

    fun text(size: Float, weight: FontWeight = FontWeight.Normal) = display(size, weight)

    fun mono(size: Float, weight: FontWeight = FontWeight.Medium) =
        display(size, weight).copy(fontFeatureSettings = "tnum")
}

private val MonitorAppTypography =
    Typography(
        headlineLarge = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Bold, fontSize = 28.sp),
        headlineMedium = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.SemiBold, fontSize = 22.sp),
        titleLarge = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.SemiBold, fontSize = 18.sp),
        titleMedium = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Medium, fontSize = 16.sp),
        bodyLarge = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Normal, fontSize = 16.sp),
        bodyMedium = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Normal, fontSize = 14.sp),
        labelLarge = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.SemiBold, fontSize = 13.sp),
        labelMedium = TextStyle(fontFamily = MonitorTypography.fontFamily, fontWeight = FontWeight.Medium, fontSize = 12.sp),
    )

/** The camera apps' Material theme: dark, the brand accent, Sora type. */
@Composable
fun MonitorAppTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme =
            darkColorScheme(
                primary = MonitorBrandColors.accent,
                background = MonitorBrandColors.background,
                surface = MonitorBrandColors.surface,
                onBackground = MonitorBrandColors.ink,
                onSurface = MonitorBrandColors.ink,
                onPrimary = MonitorBrandColors.darkText,
            ),
        typography = MonitorAppTypography,
    ) {
        ProvideTextStyle(MonitorType.text(16f), content)
    }
}
