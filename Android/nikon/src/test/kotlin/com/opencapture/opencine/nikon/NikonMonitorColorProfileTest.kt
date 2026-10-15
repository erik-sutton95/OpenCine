package com.opencapture.opencine.nikon

import com.opencapture.opencine.media.MonitorTransfer
import java.io.File
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class NikonMonitorColorProfileTest {
    @Test fun generatedLooksAndSampledReadingsMatchOriginalZVectors() {
        val rows = File(requireNotNull(System.getProperty("opencine.fixtures")),
            "monitor-log-display-look-vectors.tsv").readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }.map { it.split('\t') }
        assertEquals(40, rows.size)
        assertEquals(setOf(MonitorTransfer.LOG3G10, MonitorTransfer.NLOG),
            NikonMonitorColorProfile.rec709LookCurves.keys)
        for ((name, transform, transfer) in listOf(
            Triple("log3G10", NikonMonitorColorProfile.log3G10Rec709, MonitorTransfer.LOG3G10),
            Triple("nLog", NikonMonitorColorProfile.nLogRec709, MonitorTransfer.NLOG),
        )) {
            val rgb = transform.rgb(33)
            val curve = NikonMonitorColorProfile.rec709LookCurves.getValue(transfer)
            assertEquals(256, curve.size)
            for (row in rows.filter { it[1] == name }) {
                val r = row[3].toInt()
                if (row[0] == "rgb") {
                    val offset = (r + row[4].toInt() * 33 + row[5].toInt() * 33 * 33) * 3
                    for (channel in 0..2) {
                        assertTrue(abs(rgb[offset + channel] - row[6 + channel].toFloat()) <= 0.000001f,
                            "$name RGB row=$row channel=$channel")
                    }
                } else {
                    assertTrue(abs(curve[r] - row[6].toDouble()) <= 0.000001,
                        "$name gray index=$r")
                }
            }
        }
    }
}
