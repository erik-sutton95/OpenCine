package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * A4-45: the typed connect failure the Swift session layer sends (`AndroidConnectFailure`, pinned
 * to the same table by `AndroidConnectFailureWireTests.swift`).
 */
class CameraConnectionFailureTest {
    @Test
    fun `the wire codes are the Swift AndroidConnectFailure table`() {
        assertEquals(
            listOf(
                "OTHER=0", "REJECTED_INITIATOR=1", "BUSY=2", "CONNECTION_CLOSED=3", "TIMEOUT=4",
                "PAIRING_CHALLENGE_UNAVAILABLE=5", "SAVED_PROFILE_REQUIRED=6", "NON_NUMERIC_HOST=7",
                "UNREACHABLE=8", "CAMERA_SILENT=9",
            ),
            CameraConnectionFailure.entries.map { "$it=${it.wireCode}" },
        )
        for (failure in CameraConnectionFailure.entries) {
            assertEquals(failure, CameraConnectionFailure.fromWire(failure.wireCode))
        }
        assertEquals(CameraConnectionFailure.OTHER, CameraConnectionFailure.fromWire(99))
    }

    /** iOS `isSavedProfileUnavailable`: one fresh pairing is the remedy for exactly these. */
    @Test
    fun `a saved profile is unavailable after a refusal, a required pairing or a hang up`() {
        assertEquals(
            setOf(
                CameraConnectionFailure.REJECTED_INITIATOR,
                CameraConnectionFailure.SAVED_PROFILE_REQUIRED,
                CameraConnectionFailure.CONNECTION_CLOSED,
            ),
            CameraConnectionFailure.entries.filter { it.savedProfileUnavailable }.toSet(),
        )
    }
}
