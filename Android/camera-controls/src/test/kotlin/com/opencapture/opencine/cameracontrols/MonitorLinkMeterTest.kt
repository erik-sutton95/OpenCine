package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.ConnectionPhase
import com.opencapture.opencine.vocabulary.SessionRecoveryCopy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** A3-16: the one FPS chip word and bar policy every Android live monitor shows. */
class MonitorLinkMeterTest {
    private fun observation(
        connection: ConnectionPhase = ConnectionPhase.LIVE,
        frames: Int = 0,
        lastAt: Long? = null,
        feedRecovering: Boolean = false,
        sessionRecovering: Boolean = false,
        linkBars: Int? = null,
    ) = MonitorLinkObservation(connection, frames, lastAt, feedRecovering, sessionRecovering, linkBars)

    @Test
    fun theChipNamesTheLinkUntilPicturesArriveThenPrintsTheRate() {
        val meter = MonitorLinkMeter()
        meter.tick(observation(connection = ConnectionPhase.IDLE), 1_000)
        assertEquals("\u2014", meter.label)
        assertEquals(0, meter.bars)
        meter.tick(observation(connection = ConnectionPhase.OPENING_DATALINK), 1_200)
        assertEquals("LINK", meter.label)
        meter.tick(observation(), 1_400)
        assertEquals("LINK", meter.label, "connected without pictures")
        meter.tick(observation(frames = 5, lastAt = 1_600), 1_600)
        assertEquals("25.00", meter.label)
        assertTrue(meter.bars > 0, "a streaming link at the target rate scores bars")
    }

    @Test
    fun recoveryWordsOutrankTheRateAndTheDroppedSessionOutranksEverything() {
        val meter = MonitorLinkMeter()
        meter.tick(observation(frames = 0, lastAt = 0), 1_000)
        meter.tick(observation(frames = 5, lastAt = 1_200, feedRecovering = true), 1_200)
        assertEquals("RECOV", meter.label)
        meter.tick(observation(connection = ConnectionPhase.FAILED, frames = 5), 1_400)
        assertEquals("FAIL", meter.label)
        meter.tick(observation(connection = ConnectionPhase.FAILED, frames = 5, sessionRecovering = true), 1_600)
        assertEquals(SessionRecoveryCopy.HELD_FRAME_BADGE, meter.label)
    }

    @Test
    fun hundredthsDoNotTickTheChipAndASourceScoredLinkKeepsItsBars() {
        val meter = MonitorLinkMeter()
        meter.tick(observation(frames = 0, linkBars = 3), 1_000)
        meter.tick(observation(frames = 5, linkBars = 3), 1_200)
        assertEquals("25.00", meter.label)
        assertEquals(3, meter.bars)
        // 25.1 fps is within the 0.4 hold: the chip keeps 25.00.
        meter.tick(observation(frames = 10, linkBars = 2), 1_399)
        assertEquals("25.00", meter.label)
        assertEquals(2, meter.bars)
        meter.restart()
        meter.tick(observation(frames = 0), 2_000)
        assertEquals("25.13", meter.label, "a new counter shows the last measured rate, unheld, until it measures again")
    }

    /** Hardware pass 7.2a: a held frame drew 3 of 4 bars beside NO LINK. Nothing is delivered. */
    @Test
    fun aHeldFrameDrawsNoDeliveryBarsEvenWhenTheSourceScoresSome() {
        val meter = MonitorLinkMeter()
        meter.tick(observation(frames = 0, linkBars = 3), 1_000)
        meter.tick(observation(frames = 5, linkBars = 3), 1_200)
        assertEquals(3, meter.bars)
        meter.tick(observation(frames = 5, linkBars = 3, sessionRecovering = true), 1_400)
        assertEquals(SessionRecoveryCopy.HELD_FRAME_BADGE, meter.label)
        assertEquals(0, meter.bars)
    }
}
