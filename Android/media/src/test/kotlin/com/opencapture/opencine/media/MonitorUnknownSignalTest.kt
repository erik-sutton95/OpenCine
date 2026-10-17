package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MonitorUnknownSignalTest {
    @Test fun explicitUnknownNeverEvaluatesFallbackButLegacyDefaultsRemain() {
        var reads = 0
        val fallback = { reads++; MonitorTransfer.DLOG2 }
        assertNull(MonitorPlaybackSourceValues(allowsSignalFallback = false).resolvedTransfer(fallback))
        assertEquals(0, reads)
        assertEquals(MonitorTransfer.DLOG2, MonitorPlaybackSourceValues().resolvedTransfer(fallback))
        assertEquals(1, reads)
        assertEquals(MonitorTransfer.DLOGM,
            MonitorPlaybackSourceValues(transfer = MonitorTransfer.DLOGM, allowsSignalFallback = false).resolvedTransfer(fallback))
        assertEquals(1, reads)
    }

    @Test fun rawAxisRetainsEveryEncodedCodeWithoutCalibratedReferences() {
        val axis = ScopeLevelAxis.rawCodes
        assertFalse(axis.supportsCalibratedReferences)
        assertEquals(256, axis.table.size)
        for (code in 0..255) assertEquals(code * 100.0 / 255, axis.table[code].toDouble(), 0.0001)
        val counts = IntArray(256) { it + 1 }
        assertContentEquals(counts, axis.remapHistogram(counts))
        val legacy = ScopeLevelAxis.of(MonitorTransfer.DLOG2)
        assertTrue(legacy.supportsCalibratedReferences)
        assertEquals(legacy, ScopeLevelAxis(legacy.table, legacy.middleGrayIre))
    }
}
