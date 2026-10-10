package com.opencapture.opencine.media

import kotlin.math.ln
import kotlin.math.pow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** The Nikon curves at the values OpenZCineCore's ExposureScaleTests publish (N-Log 1.0.0, RED 915-0187 Rev C, IEC 61966-2-1). */
class TransferCurveGoldenTest {
    @Test fun log3G10MatchesTheRedMappingTable() {
        for ((linear, encoded) in listOf(-0.01 to 0.0, 0.0 to 0.091551, 0.18 to 0.333333, 1.0 to 0.493449, 184.322 to 1.0)) {
            assertEquals(encoded, Log3G10.encode(linear), 0.000005)
        }
        assertEquals(0.091551, LiveColorScience.encode(0.0, MonitorTransfer.LOG3G10), 0.000001)
        assertEquals(1.0 / 3.0, MonitorTransfer.LOG3G10.middleGrayEncoded, 0.000001)
        assertEquals(0.18, LiveColorScience.linearize(1.0 / 3.0, MonitorTransfer.LOG3G10), 0.00001)
        assertEquals(184.322348, MonitorTransfer.LOG3G10.peakLinear, 0.000001)
    }

    @Test fun nLogMatchesTheSpecification() {
        val middleGray = MonitorTransfer.NLOG.middleGrayEncoded
        assertEquals(372.032, middleGray * 1023, 0.01)
        assertEquals(0.18, LiveColorScience.linearize(middleGray, MonitorTransfer.NLOG), 0.00001)
        assertEquals(127.2, LiveColorScience.encode(0.0, MonitorTransfer.NLOG) * 1023, 0.1)
        // The segments meet at reflectance 0.328 (10-bit code 452).
        assertEquals(650.0 * (0.328 + 0.0075).pow(1.0 / 3.0), 150.0 * ln(0.328) + 619.0, 0.15)
        assertEquals(NLog.decode(451.9 / 1023), NLog.decode(452.1 / 1023), 0.001)
        assertEquals(14.780863, MonitorTransfer.NLOG.peakLinear, 0.000001)
    }

    @Test fun srgbHitsTheIecReferencePoints() {
        assertEquals(0.46136, MonitorTransfer.SRGB.middleGrayEncoded, 0.0005)
        assertEquals(0.0, LiveColorScience.encode(0.0, MonitorTransfer.SRGB))
        assertEquals(1.0, LiveColorScience.encode(1.0, MonitorTransfer.SRGB), 0.0001)
        // Display-referred: no headroom above display white.
        assertEquals(1.0, LiveColorScience.encode(2.0, MonitorTransfer.SRGB), 0.0001)
        assertEquals(0.5, LiveColorScience.linearize(LiveColorScience.encode(0.5, MonitorTransfer.SRGB), MonitorTransfer.SRGB), 0.0001)
        assertEquals(1.0, MonitorTransfer.SRGB.peakLinear)
    }

    @Test fun everyNewCurveRoundTripsAcrossItsRange() {
        for (transfer in listOf(MonitorTransfer.SRGB, MonitorTransfer.NLOG, MonitorTransfer.LOG3G10)) {
            // Codes below black decode to negative light, which linearize floors at zero.
            val black = LiveColorScience.encode(0.0, transfer)
            for (step in 1..99) {
                val encoded = step / 100.0
                if (encoded <= black) continue
                val back = LiveColorScience.encode(LiveColorScience.linearize(encoded, transfer), transfer)
                assertEquals(encoded, back, 0.000001, "$transfer at $encoded")
            }
            assertTrue(transfer.middleGrayEncoded > LiveColorScience.encode(0.0, transfer))
        }
    }
}
