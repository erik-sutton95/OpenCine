package com.opencapture.opencine.vocabulary

/**
 * Action 6 aperture strategy: `0x02/0x8E` pid `0x0044`, one byte (core `ApertureStrategy`).
 * Survey 2026-09-21, handbook `devices/action-6/settings`. Raw ids stay `Int` like the
 * other HUD fields; `-1` is unknown.
 */
object ApertureStrategy {
    /** SuperNight "Large Aperture". */
    const val F2 = 0x00
    const val F26 = 0x01
    const val F28 = 0x02
    const val STARBURST = 0x03
    const val AUTO = 0x04

    fun label(raw: Int): String? =
        when (raw) {
            F2 -> "f/2.0"
            F26 -> "f/2.6"
            F28 -> "f/2.8"
            STARBURST -> "Starburst f/4"
            AUTO -> "Auto"
            else -> null
        }

    /** Captured sets, used until the capability push lands. */
    fun fallback(expoMode: Int, shootingMode: Int): List<Int> =
        when {
            shootingMode == CameraCommands.SHOOT_SUPER_NIGHT -> listOf(F2, F28, STARBURST)
            expoMode == CameraCommands.EXPO_MANUAL -> listOf(F26, F28, STARBURST)
            else -> listOf(AUTO, F28, STARBURST)
        }

    fun choices(status: CameraStatus): List<Int> =
        status.availableApertureStrategies.ifEmpty { fallback(status.expoMode, status.shootingMode) }

    fun fNumberLabel(hundredths: Int): String = "f/%.1f".format(java.util.Locale.US, hundredths / 100.0)

    /** Tile value: live iris, else the requested strategy, else a dash. */
    fun tileValue(status: CameraStatus): String =
        when {
            status.irisHundredths > 0 -> fNumberLabel(status.irisHundredths)
            else -> label(status.apertureStrategy) ?: "—"
        }
}
