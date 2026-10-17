package com.opencapture.opencine.cameracontrols


enum class LiveSheet {
    ISO,
    SHUTTER,
    WB,
    FOCUS,
    /** Action 6 aperture strategy, in the FOCUS slot. */
    APERTURE,
    /** Capture-bar MODE: expo Auto/Manual. Not shooting Video/Photo. */
    EXPO,
    AUDIO,
    COLOR,
    FORMAT,
    /** Top-deck shooting Video/Photo/… Not capture-bar EXPO Auto/Manual. */
    MODE,
}

val LiveSheet.isRecordingSetup: Boolean
    get() = this == LiveSheet.FORMAT || this == LiveSheet.COLOR

val LiveSheet.isTopAnchored: Boolean
    get() = isRecordingSetup || this == LiveSheet.MODE

/** Lower ISO/WB/… stay visible for top FORMAT/COLOR/MODE tap or hold. */
fun hidesLowerCaptureValues(
    sheet: LiveSheet?,
    stripQuick: Boolean,
    topQuick: Boolean,
): Boolean {
    if (topQuick) return false
    if (sheet?.isTopAnchored == true) return false
    return sheet != null || stripQuick
}

val LiveSheet.headerLabel: String
    get() =
        when (this) {
            LiveSheet.ISO -> "ISO"
            LiveSheet.SHUTTER -> "SHUTTER"
            LiveSheet.WB -> "WHITE BALANCE"
            LiveSheet.FOCUS -> "FOCUS"
            LiveSheet.APERTURE -> "APERTURE"
            LiveSheet.EXPO -> "MODE"
            LiveSheet.AUDIO -> "AUDIO"
            LiveSheet.COLOR -> "COLOR"
            LiveSheet.FORMAT -> "RESOLUTION"
            LiveSheet.MODE -> "SHOOTING MODE"
        }

val LiveSheet.subtitle: String
    get() =
        when (this) {
            LiveSheet.ISO -> "Sensitivity"
            LiveSheet.SHUTTER -> "Angle · speed"
            LiveSheet.WB -> "Kelvin · auto · tint"
            LiveSheet.FOCUS -> "AF-S / AF-C"
            LiveSheet.APERTURE -> "Aperture strategy"
            LiveSheet.EXPO -> "Exposure"
            LiveSheet.AUDIO -> "Channel · wind · direction · vocal"
            LiveSheet.COLOR -> "Color mode"
            LiveSheet.FORMAT -> "Frame rate"
            LiveSheet.MODE -> "Shooting mode"
        }
