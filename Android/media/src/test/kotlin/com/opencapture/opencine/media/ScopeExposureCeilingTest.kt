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
    @Test fun aDeclaredClipReplacesCalibrationUntilWithdrawn() {
        val source = ScopeExposureCeiling(ScopeClipProfile(mapOf(
            MonitorTransfer.DLOG2 to ScopeClipCalibration(1600, 247, 248),
        ), defaultIso = 1600))
        // A camera that publishes its warning code states it; no tap may ratchet past it.
        source.declare(180, MonitorTransfer.LOG3G10)
        assertEquals(180, source.clipByte(MonitorTransfer.LOG3G10))
        assertEquals(180, source.observeTapMax(200, MonitorTransfer.LOG3G10).first)
        source.declare(230, MonitorTransfer.DLOG2)
        assertEquals(230 to false, source.observeTapMax(248, MonitorTransfer.DLOG2))
        assertEquals(230, source.clipByte(MonitorTransfer.DLOG2, 800))
        source.declare(null, MonitorTransfer.DLOG2)
        assertEquals(247, source.clipByte(MonitorTransfer.DLOG2))
        source.declare(900, MonitorTransfer.NLOG)
        assertEquals(255, source.clipByte(MonitorTransfer.NLOG))
        source.reset()
        assertEquals(255, source.clipByte(MonitorTransfer.LOG3G10))
    }
}
