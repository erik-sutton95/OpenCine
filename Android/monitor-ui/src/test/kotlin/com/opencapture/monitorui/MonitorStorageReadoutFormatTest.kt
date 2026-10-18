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
}
