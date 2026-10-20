package com.opencapture.opencine.vocabulary

/** Compatibility adapter preserving existing Android capture values. */
object ShutterAngle {
    val degrees: List<Double> = com.opencapture.opencine.media.ShutterAngle.degrees
    const val DEFAULT_DEGREES = 180.0
    val labels: List<String> = com.opencapture.opencine.media.ShutterAngle.labels

    fun effectiveFps(fps: Int): Int = com.opencapture.opencine.media.ShutterAngle.effectiveFps(fps)

    /** What a format change owes the host-emulated angle; null = no shutter write (Core decides, A5-07). */
    fun formatRematch(
        degrees: Double, usesAngle: Boolean, manual: Boolean, isPhoto: Boolean,
        previousFps: Int, nextFps: Int, available: List<Int>, alreadyPending: Boolean = false,
    ) = com.opencapture.opencine.media.ShutterAngle.formatRematch(
        degrees, usesAngle, manual, isPhoto, previousFps, nextFps, available, alreadyPending,
    )

    fun label(value: Double): String = com.opencapture.opencine.media.ShutterAngle.label(value)
    fun parse(label: String): Double? = com.opencapture.opencine.media.ShutterAngle.parse(label)
    fun denom(degrees: Double, fps: Int): Int = com.opencapture.opencine.media.ShutterAngle.denom(degrees, fps)
    fun denom(degrees: Double, fps: Int, available: List<Int>): Int =
        com.opencapture.opencine.media.ShutterAngle.denom(degrees, fps, available)

    fun degrees(denom: Int, fps: Int): Double =
        com.opencapture.opencine.media.ShutterAngle.degrees(denom, effectiveFps(fps)) ?: DEFAULT_DEGREES

    fun nearestDegrees(value: Double): Double = com.opencapture.opencine.media.ShutterAngle.nearestDegrees(value)
    fun achieved(preferredDegrees: Double, denom: Int, fps: Int): String? =
        com.opencapture.opencine.media.ShutterAngle.achieved(preferredDegrees, denom, fps)
    fun nearestLabel(denom: Int, fps: Int): String = label(nearestDegrees(degrees(denom, fps)))
}

data class EvComp(val thirds: Int) {
    val rawValue: Int get() = 0x10 + thirds
    val label: String get() = com.opencapture.opencine.media.ExposureCompensation.label(thirds)

    companion object {
        const val MINUS = "\u2212"
        const val MIN_THIRDS = -9
        const val MAX_THIRDS = 9
        val ZERO = EvComp(0)
        val allCases: List<EvComp> = (MIN_THIRDS..MAX_THIRDS).map { EvComp(it) }

        fun fromThirds(thirds: Int): EvComp = EvComp(thirds.coerceIn(MIN_THIRDS, MAX_THIRDS))
        fun fromRaw(raw: Int): EvComp? = (raw - 0x10).takeIf { it in MIN_THIRDS..MAX_THIRDS }?.let(::EvComp)
        fun fromLabel(label: String): EvComp? =
            com.opencapture.opencine.media.ExposureCompensation.fromLabel(label, MIN_THIRDS..MAX_THIRDS)?.let(::EvComp)
    }
}
