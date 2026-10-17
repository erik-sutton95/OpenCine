package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorDeliveryExportConfiguration
import com.opencapture.opencine.appkit.MonitorDeliveryFileFacts
import com.opencapture.opencine.appkit.MonitorDeliverySelectionFacts
import com.opencapture.opencine.vocabulary.MediaClipFormatting
import kotlin.test.Test
import kotlin.test.assertEquals

/** The share options footer's summary line, the twin of Swift's `MonitorOperatorDeliveryScreen.summary`. */
class DeliverySummaryTest {
    private fun selection(vararg sizes: Long?) =
        MonitorDeliverySelectionFacts(sizes.mapIndexed { i, size -> MonitorDeliveryFileFacts("C$i.MP4", size) }, sizes.size, false)

    private val original = MonitorDeliveryExportConfiguration(logTransform = 0, exportFormat = 0, bakeLUT = false)

    @Test fun oneCachedOriginalNamesItsSizeAndTheOriginal() {
        assertEquals("1 clip · ${MediaClipFormatting.byteLabel(8_906)} · Camera original",
            deliverySummary(selection(8_906), original, null))
    }

    @Test fun partlyKnownSizesAreALowerBound() {
        assertEquals("2 clips · At least ${MediaClipFormatting.byteLabel(2_000_000)} · LUT baked",
            deliverySummary(selection(2_000_000, null), original.copy(bakeLUT = true), null))
    }

    @Test fun unknownSizesAndConvertedLogSayWhatTheyAre() {
        assertEquals("2 clips · Size unavailable · Converted log",
            deliverySummary(selection(null, null), original.copy(convertLog = true), null))
    }

    @Test fun zeroBytesReadsZero() {
        assertEquals("1 clip · 0 B · Camera original", deliverySummary(selection(0), original, null))
    }
}
