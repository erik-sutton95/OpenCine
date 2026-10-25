package com.opencapture.opencine.vocabulary

/**
 * Operator HUD copy for control replies. Matches iOS `ControlHud` /
 * `CameraReply` / `Duml.shouldHoldReply`. Probe GET names stay in the journal.
 */
object ControlHud {
    const val TOAST_HOLD_SECONDS = 2.0
    const val TOAST_OPACITY = 0.72
    const val TOAST_OFFSET_FROM_FEED_TOP = 22.0

    /** Chip / pinch / color drum while rolling in D-Log2. No opcode names. */
    const val RECORDING_COLOR_LOCK_NOTE =
        "Can't change color while recording. D-Log2 can't zoom"

    /** SET / GET timeout copy. iOS `requestCamera` and `fireCamera` pass announce=false. */
    fun timeoutNote(name: String, announce: Boolean): String? =
        if (announce) "$name timed out" else null

    /**
     * Center Y for the control toast. Parks under a mounted top bar when that
     * bar overlays the feed (DISP 1). Falls back to the feed edge when the bar
     * is off or already sits above the picture (DISP 2 / portrait).
     */
    fun toastCenterY(feedMinY: Double, chromeBottomY: Double? = null): Double {
        val edge =
            if (chromeBottomY != null && chromeBottomY > feedMinY + 0.5) chromeBottomY
            else feedMinY
        return edge + TOAST_OFFSET_FROM_FEED_TOP
    }
}
