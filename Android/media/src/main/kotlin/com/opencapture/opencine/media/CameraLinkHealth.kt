package com.opencapture.opencine.media

import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Live link health: the 0-100 score from link phase, round trip and frame delivery, the bars it
// shows with hysteresis, and the rolling live-view frame rate. Names match Swift
// `CameraLinkHealthScorer` and `LinkSignalBars`.

enum class CameraLinkPhase {
    DISCONNECTED,
    CONNECTING,
    CONNECTED_IDLE,
    STREAMING,
    RECOVERING,
    DEMO,
}

data class CameraLinkHealthInputs(
    val phase: CameraLinkPhase = CameraLinkPhase.DISCONNECTED,
    val ptpRoundTripMilliseconds: Double? = null,
    val liveViewFPS: Double? = null,
    val targetLiveViewFPS: Double = 30.0,
    val secondsSinceLastGoodFrame: Double? = null,
    val consecutiveBadFrames: Int = 0,
    val recentCommandFailures: Int = 0,
    val isRecoveringStream: Boolean = false,
)

data class CameraLinkHealthSnapshot(val linkHealthScore: Int, val detailCaption: String)

object CameraLinkHealthScorer {
    fun latencyScore(milliseconds: Double): Double =
        when {
            milliseconds < 30 -> 100.0
            milliseconds < 60 -> 92.0
            milliseconds < 100 -> 82.0
            milliseconds < 150 -> 68.0
            milliseconds < 250 -> 48.0
            milliseconds < 500 -> 28.0
            else -> 10.0
        }

    fun frameDeliveryScore(actualFPS: Double, targetFPS: Double): Double {
        if (actualFPS <= 0 || targetFPS <= 0) return 0.0
        return min(1.0, actualFPS / targetFPS) * 100.0
    }

    fun frameFreshnessPenalty(secondsSinceLastGoodFrame: Double?): Double {
        val s = secondsSinceLastGoodFrame ?: return 0.0
        return when {
            s < 0.5 -> 0.0
            s < 1.5 -> 8.0
            s < 3.0 -> 20.0
            s < 5.0 -> 35.0
            else -> 55.0
        }
    }

    fun badFramePenalty(consecutiveBadFrames: Int): Double =
        when {
            consecutiveBadFrames <= 0 -> 0.0
            consecutiveBadFrames <= 2 -> 6.0
            consecutiveBadFrames <= 5 -> 18.0
            consecutiveBadFrames <= 8 -> 32.0
            else -> 50.0
        }

    fun commandFailurePenalty(recentFailures: Int): Double =
        when {
            recentFailures <= 0 -> 0.0
            recentFailures == 1 -> 15.0
            recentFailures == 2 -> 30.0
            else -> 50.0
        }

    fun score(inputs: CameraLinkHealthInputs): CameraLinkHealthSnapshot {
        when (inputs.phase) {
            CameraLinkPhase.DISCONNECTED ->
                return CameraLinkHealthSnapshot(0, "Not connected")
            CameraLinkPhase.DEMO ->
                return CameraLinkHealthSnapshot(85, "Demo session")
            CameraLinkPhase.CONNECTING ->
                return CameraLinkHealthSnapshot(20, "Connecting…")
            else -> Unit
        }
        val latency = inputs.ptpRoundTripMilliseconds?.let(::latencyScore) ?: 0.0
        val fps = inputs.liveViewFPS
        val streaming =
            inputs.phase == CameraLinkPhase.STREAMING || inputs.phase == CameraLinkPhase.RECOVERING
        val frameScore =
            if (fps != null && streaming) {
                frameDeliveryScore(fps, inputs.targetLiveViewFPS)
            } else {
                0.0
            }
        val linkHealthRaw =
            if (streaming) {
                val lc = if (latency > 0) latency else 70.0
                frameScore * 0.55 + lc * 0.25 + 20.0 -
                    frameFreshnessPenalty(inputs.secondsSinceLastGoodFrame) -
                    badFramePenalty(inputs.consecutiveBadFrames) -
                    commandFailurePenalty(inputs.recentCommandFailures) -
                    if (inputs.isRecoveringStream) 25.0 else 0.0
            } else {
                val lc = if (latency > 0) latency else 60.0
                lc * 0.75 + 25.0 -
                    commandFailurePenalty(inputs.recentCommandFailures) -
                    if (inputs.isRecoveringStream) 25.0 else 0.0
            }
        return CameraLinkHealthSnapshot(
            linkHealthScore = linkHealthRaw.roundToInt().coerceIn(0, 100),
            detailCaption = "Command channel warm",
        )
    }
}

/** Rolling live-view delivery rate. Displayed rate throttles to ~1 Hz. */
class FrameRateSampler(
    windowSize: Int = 30,
    displayRefreshInterval: Double = 1.0,
) {
    private val windowSize = max(1, windowSize)
    private val displayInterval = max(0.0, displayRefreshInterval)
    private val intervals = ArrayList<Double>()
    private var lastTimestamp: Double? = null
    private var lastDisplayTimestamp: Double? = null
    var displayFPS: Double = 0.0
        private set

    fun recordFrame(at: Double) {
        val previous = lastTimestamp
        lastTimestamp = at
        if (previous == null || at <= previous) return
        intervals.add(at - previous)
        if (intervals.size > windowSize) intervals.removeAt(0)
        val last = lastDisplayTimestamp
        if (last != null && at - last < displayInterval) return
        displayFPS = currentFPS
        lastDisplayTimestamp = at
    }

    /** Instantaneous Hz from a present counter over a wall-clock window. */
    fun recordFrameRate(fps: Double) {
        displayFPS = fps.coerceAtLeast(0.0)
    }

    val intervalCount: Int get() = intervals.size

    val currentFPS: Double
        get() {
            if (intervals.isEmpty()) return 0.0
            val average = intervals.sum() / intervals.size
            return 1.0 / average
        }

    val formatted: String get() = String.format(Locale.US, "%.2f", displayFPS)
}

/** 0-4 bars from the 0-100 link-health score, with hysteresis. */
class LinkSignalBars(hysteresisMargin: Int = 6) {
    var bars: Int = 0
        private set
    private val margin = max(0, hysteresisMargin)

    fun update(score: Int): Int {
        val raw = rawBars(score)
        when {
            raw == bars -> Unit
            bars == 0 || raw == 0 -> bars = raw
            raw > bars -> if (score >= floorScore(raw) + margin) bars = raw
            else -> if (score < floorScore(bars) - margin) bars = raw
        }
        return bars
    }

    companion object {
        private fun floorScore(of: Int): Int = 25 * (of - 1) + 1

        private fun rawBars(score: Int): Int {
            if (score <= 0) return 0
            return min(4, max(1, kotlin.math.ceil(score / 25.0).toInt()))
        }
    }
}
