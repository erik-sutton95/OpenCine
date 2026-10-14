package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Swift twin: MonitorTransferWireTests. Named curves are distinct from raw camera identifiers. */
class MonitorTransferWireTest {
    @Test fun namedCurvesRoundTripWithoutDependingOnEnumOrder() {
        val vectors = listOf(MonitorTransfer.REC709 to "rec709", MonitorTransfer.HDR to "hdr",
            MonitorTransfer.DLOG to "dlog", MonitorTransfer.DLOG2 to "dlog2", MonitorTransfer.DLOGM to "dlogm",
            MonitorTransfer.ILOG to "ilog", MonitorTransfer.SRGB to "srgb", MonitorTransfer.NLOG to "nlog",
            MonitorTransfer.LOG3G10 to "log3G10")
        assertEquals(MonitorTransfer.entries.size, vectors.size)
        for ((value, name) in vectors) {
            assertEquals(name, MonitorTransferWire.tag(value))
            assertEquals(value, MonitorTransferWire.transfer(name))
        }
    }

    @Test fun missingAndUnclassifiedNamesStayUnknown() {
        for (name in listOf(null, "", "65536", "unknown", "HDR", "PQ", "Dolby Vision", " ilog ")) {
            assertNull(MonitorTransferWire.transfer(name))
        }
    }
}
