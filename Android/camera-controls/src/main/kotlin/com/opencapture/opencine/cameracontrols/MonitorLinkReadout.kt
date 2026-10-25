package com.opencapture.opencine.cameracontrols

import android.os.SystemClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import com.opencapture.opencine.media.CameraLinkHealthInputs
import com.opencapture.opencine.media.CameraLinkHealthScorer
import com.opencapture.opencine.media.FrameRateSampler
import com.opencapture.opencine.media.LinkSignalBars
import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.SessionRecoveryCopy
import kotlinx.coroutines.delay

/** What a live source observes about its link; the app publishes it, [MonitorLinkMeter] decides the readout. */
data class MonitorLinkObservation(
    val connection: ConnectionPhase,
    /** Pictures presented so far on the current counter; the rate is derived from it. */
    val framesPresented: Int,
    /** `SystemClock.elapsedRealtime()` of the last presented picture, null before the first. */
    val lastPresentedAtMillis: Long?,
    /** The session is up but its stream is being restarted. */
    val feedRecovering: Boolean,
    /** The session itself dropped and bounded recovery holds the last frame. */
    val sessionRecovering: Boolean = false,
    /**
     * Bars a source scores itself from observations the shared inputs cannot carry (a transport
     * watchdog or link quality inside the native session); null scores [connection], rate,
     * freshness and recovery with [CameraLinkHealthScorer].
     */
    val linkBars: Int? = null,
)

/**
 * The FPS chip word and the signal bars every live monitor shows (A3-16, A5-17): the rate measured from
 * the presented-picture counter, worded by [chipLabel] and held by [LiveChromeReadout.holdFPS] so
 * hundredths do not tick the chip. One [tick] per readout period. Swift twin: `MonitorLinkMeter` in
 * OpenCineCameraVocabulary; both suites read `Fixtures/link-readout-vectors.tsv`.
 */
class MonitorLinkMeter {
    private val sampler = FrameRateSampler()
    private val signalBars = LinkSignalBars()
    private var lastCount = 0
    private var lastAtMillis = 0L
    private var held = IDLE

    var label: String by mutableStateOf(IDLE)
        private set
    var bars: Int by mutableIntStateOf(0)
        private set

    /** The picture counter was replaced: the next tick measures from zero. */
    fun restart() {
        lastCount = 0
        lastAtMillis = 0L
        held = IDLE
    }

    fun tick(observation: MonitorLinkObservation, nowMillis: Long) {
        val count = observation.framesPresented
        if (lastAtMillis > 0L && nowMillis > lastAtMillis) {
            val instant = (count - lastCount) * 1000.0 / (nowMillis - lastAtMillis).toDouble()
            if (instant >= 0.0) sampler.recordFrameRate(instant)
        }
        lastCount = count
        lastAtMillis = nowMillis
        val measured = sampler.displayFPS
        held = LiveChromeReadout.holdFPS(
            chipLabel(observation.connection, observation.feedRecovering, observation.sessionRecovering,
                sampler.formatted, measured),
            held)
        label = held
        val scored = observation.linkBars ?: signalBars.update(CameraLinkHealthScorer.score(CameraLinkHealthInputs(
            phase = LiveViewLink.cameraLinkPhase(observation.connection, observation.feedRecovering, measured),
            liveViewFPS = measured.takeIf { it > 0 },
            targetLiveViewFPS = LiveViewLink.TARGET_FPS,
            secondsSinceLastGoodFrame = observation.lastPresentedAtMillis?.let { (nowMillis - it) / 1000.0 },
            isRecoveringStream = observation.feedRecovering,
        )).linkHealthScore)
        // A held frame is not a delivered one: no bars beside the held-frame badge.
        bars = if (observation.sessionRecovering) 0 else scored
    }

    companion object {
        private const val IDLE = "\u2014"
        private const val PERIOD_MILLIS = 200L

        fun compactFPS(incoming: String): String = incoming.removeSuffix(".00").ifEmpty { IDLE }

        fun formatMeasuredFPS(fps: Double): String {
            if (fps <= 0.0) return ""
            val rounded = kotlin.math.round(fps)
            return if (kotlin.math.abs(fps - rounded) < 0.05) rounded.toInt().toString()
                else String.format(java.util.Locale.US, "%.2f", fps)
        }

        /**
         * The chip word: the held-frame badge while a dropped session holds the last frame, FAIL,
         * RECOV while the stream restarts, the measured rate, a dash while idle, else LINK.
         */
        fun chipLabel(
            connection: ConnectionPhase,
            feedRecovering: Boolean,
            sessionRecovering: Boolean,
            formattedFPS: String,
            measuredFPS: Double,
        ): String = when {
            sessionRecovering -> SessionRecoveryCopy.HELD_FRAME_BADGE
            connection == ConnectionPhase.FAILED -> "FAIL"
            feedRecovering -> "RECOV"
            measuredFPS > 0 -> formattedFPS
            connection == ConnectionPhase.IDLE -> IDLE
            else -> "LINK"
        }
    }

    internal suspend fun measure(observe: () -> MonitorLinkObservation) {
        restart()
        while (true) {
            tick(observe(), SystemClock.elapsedRealtime())
            delay(PERIOD_MILLIS)
        }
    }
}

/**
 * Runs the shared link readout for the screen's lifetime. [counterKey] names the picture counter
 * behind [MonitorLinkObservation.framesPresented]; a new key measures from zero again.
 */
@Composable
fun rememberMonitorLinkReadout(counterKey: Any?, observe: () -> MonitorLinkObservation): MonitorLinkMeter {
    val meter = remember { MonitorLinkMeter() }
    val latest by rememberUpdatedState(observe)
    LaunchedEffect(meter, counterKey) { meter.measure { latest() } }
    return meter
}
