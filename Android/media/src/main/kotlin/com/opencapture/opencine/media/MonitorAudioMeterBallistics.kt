package com.opencapture.opencine.media

import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/** One channel of a broadcast-style dBFS bar and its held peak. */
data class MonitorAudioMeterChannel(
    val levelDB: Double = MonitorAudioMeterBallistics.FLOOR_DB,
    val peakDB: Double = MonitorAudioMeterBallistics.FLOOR_DB,
    val peakAge: Double = 0.0,
) {
    companion object {
        val Silent = MonitorAudioMeterChannel()
    }
}

data class MonitorAudioMeterLevels(
    val left: MonitorAudioMeterChannel,
    val right: MonitorAudioMeterChannel,
) {
    companion object {
        val Silent = MonitorAudioMeterLevels(MonitorAudioMeterChannel.Silent, MonitorAudioMeterChannel.Silent)
    }
}

/**
 * Instant attack, timed decay, peak hold. Source snapshots supply linear peaks and elapsed seconds.
 */
object MonitorAudioMeterBallistics {
    const val FLOOR_DB = -60.0
    const val LEVEL_DECAY_PER_SECOND = 26.0
    const val PEAK_HOLD_SECONDS = 1.8
    const val PEAK_DECAY_PER_SECOND = 12.0

    fun decibels(fromLinear: Double): Double {
        if (fromLinear <= 0.0) return FLOOR_DB
        return max(FLOOR_DB, min(0.0, 20.0 * log10(fromLinear)))
    }

    fun step(channel: MonitorAudioMeterChannel, peakLinear: Double, dt: Double): MonitorAudioMeterChannel {
        val stepDt = max(0.0, dt)
        val incoming = decibels(fromLinear = peakLinear)
        val decayed = max(FLOOR_DB, channel.levelDB - LEVEL_DECAY_PER_SECOND * stepDt)
        val level = max(incoming, decayed)
        val (peak, age) =
            if (incoming >= channel.peakDB) {
                incoming to 0.0
            } else {
                val nextAge = channel.peakAge + stepDt
                val nextPeak =
                    if (nextAge > PEAK_HOLD_SECONDS) {
                        max(FLOOR_DB, channel.peakDB - PEAK_DECAY_PER_SECOND * stepDt)
                    } else {
                        channel.peakDB
                    }
                nextPeak to nextAge
            }
        return MonitorAudioMeterChannel(levelDB = level, peakDB = max(peak, level), peakAge = age)
    }
}
