package com.opencapture.opencine.vocabulary

enum class GimbalMode(val label: String) {
    FOLLOW("Follow"),
    TILT_LOCKED("Tilt locked"),
    FPV("FPV"),
    DIRECTION_LOCK("Direction Lock"),
    ;

    /** The session's own name for this mode (for example Roll Lock or FPV-V). */
    fun label(profile: CameraLabelProfile): String = profile.gimbalModeLabels[this] ?: label

    companion object {
        val pickerOrder = listOf(FOLLOW, TILT_LOCKED, FPV, DIRECTION_LOCK)
    }
}

enum class GimbalSpeed(val wire: Int, val label: String) {
    FAST(0, "Fast"),
    DEFAULT(1, "Default"),
    SLOW(2, "Slow"),
    ;

    companion object {
        val pickerOrder = listOf(SLOW, DEFAULT, FAST)

        fun fromWire(value: Int): GimbalSpeed? = entries.firstOrNull { it.wire == value }
    }
}

enum class GimbalRamp(val raw: Int, val label: String, val tau: Double) {
    OFF(0, "Off", 0.0),
    SOFT(1, "Soft", 0.35),
    MEDIUM(2, "Medium", 0.18),
    ;

    companion object {
        val pickerOrder = listOf(OFF, SOFT, MEDIUM)

        fun fromRaw(value: Int): GimbalRamp = entries.firstOrNull { it.raw == value } ?: OFF
    }
}

/** Stick double-tap and gamepad Circle/B: body recenter or a world-level snap. */
enum class GimbalDoubleTap(val raw: Int, val label: String) {
    RECENTER(0, "Recenter"),
    LEVEL(1, "Level"),
    ;

    companion object {
        val pickerOrder = listOf(RECENTER, LEVEL)

        fun fromRaw(value: Int): GimbalDoubleTap = entries.firstOrNull { it.raw == value } ?: RECENTER
    }
}

object GimbalHudCopy {
    const val POSE_NOT_READY = "Gimbal pose not ready"
    const val NEED_AB = "Set A and B to run"
    const val HOLD_STILL = "Hold the gimbal still"
    const val TITLE = "Gimbal"
    const val MODE = "Mode"
    const val SPEED = "Speed"
    const val RAMP = "Ramp"
    const val PROGRAMMED = "Motion Control"
    const val RUN = "Start"
    const val STOP = "Stop"
}
