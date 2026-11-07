package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class TeleprompterPlaybackTest {
    @Test fun pauseResumeAndManualScrollRetainTheReadingPosition() {
        val playback = TeleprompterPlayback()
        playback.play()
        playback.advance(2.0, 30.0, 500.0)
        assertEquals(60.0, playback.position)
        playback.pause()
        playback.advance(100.0, 30.0, 500.0)
        assertEquals(60.0, playback.position)
        playback.play()
        playback.advance(0.5, 60.0, 500.0)
        assertEquals(90.0, playback.position)
        playback.seek(240.0)
        assertFalse(playback.isPlaying)
        playback.play()
        playback.advance(1.0, 30.0, 500.0)
        assertEquals(270.0, playback.position)
    }

    @Test fun reachingTheEndStopsAndResetReturnsToTheBeginning() {
        val playback = TeleprompterPlayback()
        playback.play()
        playback.advance(10.0, 30.0, 125.0)
        assertEquals(125.0, playback.position)
        assertFalse(playback.isPlaying)
        playback.reset()
        assertEquals(0.0, playback.position)
        assertFalse(playback.isPlaying)
        playback.play()
        playback.advance(1.0, 30.0, 0.0)
        assertEquals(0.0, playback.position)
        assertFalse(playback.isPlaying)
    }
}
