package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** The charging fact every DJI producer reads (twin of Swift CameraStatusChargingReadingTests). */
class CameraStatusChargingReadingTest {
    @Test fun declaredReportsWinAndAnAbsentReportIsNeverFalse() {
        assertNull(CameraStatus().chargingReading, "No report is unknown, not false")
        assertEquals(true, CameraStatus(charging = true).chargingReading)
        assertEquals(false, CameraStatus(charging = true, chargingObservation = false, chargingObservationDeclared = true).chargingReading)
        assertNull(CameraStatus(chargingObservationDeclared = true).chargingReading, "An invalid declared report stays unknown")
    }
}
