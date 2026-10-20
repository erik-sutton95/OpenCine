package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class ScopeExposureCeilingTest {
    @Test fun anUnreportedISOKeepsTheLastReportUnlessTheProfileNamesAnAssumption() {
        val calibrations = mapOf(MonitorTransfer.DLOG2 to ScopeClipCalibration(1600, 247, 248))
        val keeps = ScopeExposureCeiling(ScopeClipProfile(calibrations, defaultIso = 1600))
        keeps.syncISO(800)
        keeps.syncISO(0)
        keeps.syncISO(-1)
        keeps.syncISO(null)
        assertEquals(800, keeps.resolvedISO())
        val assumes = ScopeExposureCeiling(ScopeClipProfile(calibrations, defaultIso = 1600, unreportedIso = 100))
        assumes.syncISO(800)
        assertEquals(231, assumes.clipByte(MonitorTransfer.DLOG2))
        assumes.syncISO(0)
        assertEquals(100, assumes.resolvedISO())
        kotlin.test.assertTrue(assumes.clipByte(MonitorTransfer.DLOG2) < 231)
        assumes.syncISO(25)
        assertEquals(100, assumes.resolvedISO())
        assumes.syncISO(1600)
        assertEquals(247, assumes.clipByte(MonitorTransfer.DLOG2))
    }
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
