package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

/** Twin of `LiveStreamOverlayPlacementTests.swift` and the compact line cases there. */
class LiveStreamOverlayPlacementTest {
    @Test fun anchorsUnderStatusTrailing() {
        val point = LiveStreamOverlayPlacement.anchor(MonitorRect(0f, 47f, 393f, 44f),
            viewportWidth = 393f, safeTop = 0f, safeTrailing = 0f)
        assertEquals(LiveStreamOverlayPlacement.Point(385f, 97f), point)
    }

    @Test fun statusOffStillTopTrailing() {
        val point = LiveStreamOverlayPlacement.anchor(MonitorRect(0f, 0f, 0f, 0f),
            viewportWidth = 852f, safeTop = 0f, safeTrailing = 59f)
        assertEquals(LiveStreamOverlayPlacement.Point(785f, 16f), point)
    }

    @Test fun compactLine() {
        val live = LiveStreamStatusState(LiveStreamPhase.Live, elapsedSeconds = 724, sentBitrateBps = 6_000_000,
            droppedGroups = 0, health = LiveStreamHealth.GOOD)
        assertEquals("1080p · 6 Mbps · good", live.compactLine(LiveStreamQuality(1920, 1080, 30.0, 6_000_000)))
        assertEquals("720p · 6 Mbps · good", live.compactLine(LiveStreamQuality(720, 1280, 30.0, 6_000_000)))
        val congested = live.copy(droppedGroups = 3, health = LiveStreamHealth.CONGESTED)
        assertEquals("6 Mbps · 3 dropped · slow network", congested.compactLine(null))
    }
}
