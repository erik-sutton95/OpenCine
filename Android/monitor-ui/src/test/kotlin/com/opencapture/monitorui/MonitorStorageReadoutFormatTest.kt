package com.opencapture.monitorui

import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorStorageReadoutFormatTest {
    @Test fun unknownAndEmptyCapacityKeepDifferentMeaningsInBothUnits() {
        assertEquals("\u2014", MonitorStorageReadoutFormat.capacity(null))
        assertEquals("\u2014", MonitorStorageReadoutFormat.capacity(-1))
        assertEquals("0 GB", MonitorStorageReadoutFormat.capacity(0))
        assertEquals("2048 GB", MonitorStorageReadoutFormat.capacity(2048))
        assertEquals("\u2014 Min", MonitorStorageReadoutFormat.remainingMinutes(null))
        assertEquals("\u2014 Min", MonitorStorageReadoutFormat.remainingMinutes(-1))
        assertEquals("0 Min", MonitorStorageReadoutFormat.remainingMinutes(0))
        assertEquals("180 Min", MonitorStorageReadoutFormat.remainingMinutes(180))
    }

    @Test fun portraitCapacityKeepsNearestWholeUnitAndCompactUppercaseUnit() {
        assertEquals("\u2014", MonitorStorageReadoutFormat.wholeUnitCapacity(null))
        assertEquals("\u2014", MonitorStorageReadoutFormat.wholeUnitCapacity(-1))
        assertEquals("0B", MonitorStorageReadoutFormat.wholeUnitCapacity(0))
        assertEquals("999B", MonitorStorageReadoutFormat.wholeUnitCapacity(999))
        assertEquals("2KB", MonitorStorageReadoutFormat.wholeUnitCapacity(1500))
        assertEquals("47GB", MonitorStorageReadoutFormat.wholeUnitCapacity(47_400_000_000))
        assertEquals("905GB", MonitorStorageReadoutFormat.wholeUnitCapacity(904_750_000_000))
        assertEquals("1GB", MonitorStorageReadoutFormat.wholeUnitCapacity(999_600_000))
        assertEquals("1TB", MonitorStorageReadoutFormat.wholeUnitCapacity(1_000_000_000_000))
    }

    /**
     * A5-11: the free percentage is the storage readout's alternative; video adds the remaining
     * recording time when the body reports one; photo never shows minutes (behavior audit
     * II-130, PIA-252, PAA-248).
     */
    @Test fun oneTapStepsFromFreeSpaceToPercentThenRecordingTime() {
        assertEquals(listOf("47%", "~47 Min"), MonitorStorageReadoutFormat.alternatives("47%", "~47 Min", photo = false))
        assertEquals(listOf("47%"), MonitorStorageReadoutFormat.alternatives("47%", null, photo = false))
        assertEquals(listOf("47%"), MonitorStorageReadoutFormat.alternatives("47%", "~47 Min", photo = true))
        assertEquals(emptyList(), MonitorStorageReadoutFormat.alternatives(null, "~47 Min", photo = true))
        assertEquals(emptyList(), MonitorStorageReadoutFormat.alternatives(null, null, photo = false))
    }

    /** A tap with nothing to step to leaves the readout on its free space, so a later alternative starts from free space too. */
    @Test fun aTapStepsOnlyWhenThereIsAnAlternative() {
        assertEquals(1, MonitorStorageReadoutFormat.nextForm(0, 3))
        assertEquals(0, MonitorStorageReadoutFormat.nextForm(2, 3))
        assertEquals(0, MonitorStorageReadoutFormat.nextForm(0, 1))
        assertEquals(0, MonitorStorageReadoutFormat.nextForm(5, 1))
        assertEquals(0, MonitorStorageReadoutFormat.nextForm(5, 2))
    }
}
