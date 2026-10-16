package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CameraStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Swift twin: DjiNativeWireTests charging observations round-trip through the JNI facade. */
class CameraStatusChargingJSONTest {
    @Test fun declaredChargeKeepsFalseTrueAndExplicitUnknown() {
        for (charging in listOf(false, true, null)) {
            val reported = CameraStatus(charging = true, chargingObservation = charging, chargingObservationDeclared = true)
            val decoded = CameraStatus.fromJson(reported.toJson())
            assertEquals(charging, decoded.chargingObservation)
            assertTrue(decoded.chargingObservationDeclared)
        }
        val legacy = CameraStatus.fromJson("{\"charging\":false}")
        assertNull(legacy.chargingObservation)
        assertFalse(legacy.chargingObservationDeclared)
        val unknown = CameraStatus.fromJson("{\"charging\":true,\"chargingObservation\":null}")
        assertNull(unknown.chargingObservation)
        assertTrue(unknown.chargingObservationDeclared)
    }
}
