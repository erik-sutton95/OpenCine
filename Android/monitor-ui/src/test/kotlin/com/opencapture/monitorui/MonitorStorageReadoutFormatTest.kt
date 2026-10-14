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
}
