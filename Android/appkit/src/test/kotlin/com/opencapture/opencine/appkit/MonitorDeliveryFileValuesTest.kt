package com.opencapture.opencine.appkit

import org.junit.Assert.*
import org.junit.Test

class MonitorDeliveryFileValuesTest {
    @Test fun originalNameAndContainerCaseRemainExact() {
        val configuration = MonitorDeliveryExportConfiguration(1, 1)
        assertEquals("SIMULATED.mov", MonitorDeliveryFileNaming.filename("SIMULATED.MP4", configuration, "mov"))
        assertEquals("SIMULATED.MP4", MonitorDeliveryFileNaming.filename("SIMULATED.MP4", configuration.copy(bakeLUT = false), "mov"))
    }
    @Test fun convertedTagDoesNotRenameAnUnconvertedOriginal() {
        val configuration = MonitorDeliveryExportConfiguration(1, 1)
        assertEquals("SIMULATED.mov", MonitorDeliveryFileNaming.filename("SIMULATED.MP4", configuration, "mov", "log"))
        assertEquals("SIMULATED.log.mov", MonitorDeliveryFileNaming.filename("SIMULATED.MP4", configuration.copy(convertLog = true), "mov", "log"))
    }
    @Test fun missingMetadataNeverInvokesAnInventedByteFormatter() {
        val unknown = MonitorDeliveryMetadataFacts("SIMULATED", null, null)
        val formatted = mutableListOf<Long>()
        val text = MonitorDeliveryMetadataSummary.text(listOf(unknown)) { formatted += it; "unexpected" }
        assertNull(unknown.captureDate); assertNull(unknown.sizeBytes); assertTrue(formatted.isEmpty())
        assertEquals("SIMULATED · unknown date · unknown size", text)
    }
    @Test fun metadataOrderAndKnownValuesRemainExact() {
        val text = MonitorDeliveryMetadataSummary.text(listOf(
            MonitorDeliveryMetadataFacts("SIMULATED-A", "2026-10-07", 123), MonitorDeliveryMetadataFacts("SIMULATED-B", null, null)
        )) { "$it bytes" }
        assertEquals("SIMULATED-A · 2026-10-07 · 123 bytes\nSIMULATED-B · unknown date · unknown size", text)
    }
    @Test fun conversionWinsOverLutMetadataAndDisabledMetadataIncludesNothing() {
        val configuration = MonitorDeliveryExportConfiguration(1, 1)
        val baked = MonitorDeliveryMetadataSelection(configuration)
        assertTrue(baked.included); assertTrue(baked.bakedLook); assertTrue(baked.bakedExposure); assertFalse(baked.convertedCurve)
        val converted = MonitorDeliveryMetadataSelection(configuration.copy(convertLog = true))
        assertTrue(converted.included); assertFalse(converted.bakedLook); assertFalse(converted.bakedExposure); assertTrue(converted.convertedCurve)
        val absent = MonitorDeliveryMetadataSelection(configuration.copy(convertLog = true, includeMetadata = false))
        assertFalse(absent.included); assertFalse(absent.bakedLook); assertFalse(absent.bakedExposure); assertFalse(absent.convertedCurve)
    }
}
