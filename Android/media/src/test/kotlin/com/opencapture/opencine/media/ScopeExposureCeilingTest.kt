package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class ScopeExposureCeilingTest {
    @Test fun unknownSourceDoesNotInventISOOrCalibration() {
        val source = ScopeExposureCeiling()
        assertNull(source.resolvedISO())
        assertEquals(255, source.clipByte(MonitorTransfer.DLOG2))
        assertFalse(source.observeTapMax(247, MonitorTransfer.DLOG2).second)
    }
    @Test fun storedBundleKeepsSamplingTimeCeiling() {
        val source = ScopeExposureCeiling(ScopeClipProfile(mapOf(
            MonitorTransfer.DLOG2 to ScopeClipCalibration(1600, 247, 248),
        ), defaultIso = 1600))
        assertEquals(247, source.clipByte(MonitorTransfer.DLOG2, 0))
        assertEquals(247, source.clipByte(MonitorTransfer.DLOG2, -1))
        val bytes = ByteArray(4 * 4 * 4) { 120 }
        val held = ScopeSampler.sample(bytes, 4, 4, 16, MonitorTransfer.DLOG2,
            includePoints = false, ceiling = source)
        source.setISO(800)
        assertEquals(231, source.clipByte(MonitorTransfer.DLOG2))
        assertEquals(247, held.ceiling.byte)
        source.reset()
        assertEquals(247, source.clipByte(MonitorTransfer.DLOG2))
        assertEquals(247, held.ceiling.byte)
    }
}
