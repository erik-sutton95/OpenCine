package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MonitorAudioMeterBallisticsTest {
    @Test fun linearMapsToDecibels() {
        for ((linear, expected) in listOf(1.0 to 0.0, 0.5 to -6.0206, 2.0 to 0.0,
            0.0 to -60.0, -1.0 to -60.0, 0.00001 to -60.0)) {
            assertEquals(expected, MonitorAudioMeterBallistics.decibels(linear), 0.01)
        }
    }

    @Test fun attackIsInstant() {
        val next = MonitorAudioMeterBallistics.step(MonitorAudioMeterChannel.Silent, 1.0, 0.04)
        assertEquals(0.0, next.levelDB)
        assertEquals(0.0, next.peakDB)
        assertEquals(0.0, next.peakAge)
    }

    @Test fun levelDecaysAtTheDocumentedRate() {
        val loud = MonitorAudioMeterBallistics.step(MonitorAudioMeterChannel.Silent, 1.0, 0.04)
        val dt = 0.5
        val next = MonitorAudioMeterBallistics.step(loud, 0.0, dt)
        assertEquals(-MonitorAudioMeterBallistics.LEVEL_DECAY_PER_SECOND * dt, next.levelDB, 1e-9)
    }

    @Test fun peakHoldsThroughTheHoldWindowThenDecays() {
        var channel = MonitorAudioMeterBallistics.step(MonitorAudioMeterChannel.Silent, 1.0, 0.04)
        channel = MonitorAudioMeterBallistics.step(channel, 0.0, 1.0)
        assertEquals(0.0, channel.peakDB)
        assertTrue(channel.levelDB < 0.0)
        channel = MonitorAudioMeterBallistics.step(channel, 0.0, 1.0)
        assertTrue(channel.peakAge > MonitorAudioMeterBallistics.PEAK_HOLD_SECONDS)
        assertTrue(channel.peakDB < 0.0)
    }
}
