package com.opencapture.monitorui

/**
 * The SIMULATED camera values a [ReviewLaunch] with [ReviewLaunch.Screen.LIVE] stages, so every
 * app's debug review shows the same live monitor. Each app maps them into its own integration's
 * session and adds only its own colour name (D-Log2, I-Log). Twin of Swift `ReviewLiveValues`
 * (MonitorPresentation); both read `Fixtures/review-live-values.tsv`. Debug review only; nothing
 * here reaches a camera.
 */
public data class ReviewLiveValues(
    val iso: Int = 1600,
    val shutterDenominator: Int = 50,
    val whiteBalanceKelvin: Int = 5600,
    val recordWidth: Int = 3840,
    val recordHeight: Int = 2160,
    val framesPerSecond: Int = 25,
    val batteryPercent: Int = 68,
    val storageFreeMebibytes: Long = 107L * 1024,
    val storageTotalMebibytes: Long = 128L * 1024,
    val timecodeHours: Int = 15,
    val timecodeMinutes: Int = 39,
    val timecodeSeconds: Int = 50,
) {
    public val storageFreeBytes: Long get() = storageFreeMebibytes * 1_048_576
    public val storageTotalBytes: Long get() = storageTotalMebibytes * 1_048_576

    public companion object {
        /** The one fixture every app's LIVE review stages. */
        public val SIMULATED: ReviewLiveValues = ReviewLiveValues()
    }
}
