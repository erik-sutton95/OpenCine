package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The control link checks which camera it reached against the serial Bluetooth read (Swift
 * `openControl`, same failure code), so Android never streams one camera in another's place.
 */
class LunaDeviceIdentityTest {
    /** A device-information reply's options as the camera sends them. */
    private fun options(serial: String?) =
        LunaWire.blob(48, "Insta360 Luna Ultra".toByteArray()) +
            (serial?.let { LunaWire.blob(15, it.toByteArray()) } ?: ByteArray(0)) +
            LunaWire.blob(30, "1.1.15".toByteArray())

    @Test fun aLinkToAnotherCameraIsRefusedAsSerialMismatch() {
        for (reached in listOf("IAQEB2502FGHIJ", null)) {
            val refusal = LunaDeviceIdentity.mismatch(options(reached), expectedSerial = "IAQEB2502ABCDE")
            assertEquals(ConnectionFailure.Reason.WrongCamera, refusal?.reason)
            assertEquals("com.opencapture.insta360.luna.wifi.serial-mismatch", refusal?.code)
        }
    }

    @Test fun theRequestedCameraOrAnUnknownSerialIsAccepted() {
        assertNull(LunaDeviceIdentity.mismatch(options("IAQEB2502ABCDE"), expectedSerial = "IAQEB2502ABCDE"))
        assertNull(LunaDeviceIdentity.mismatch(options("IAQEB2502FGHIJ"), expectedSerial = null), "saved Wi-Fi without Bluetooth has no serial to check")
    }

    @Test fun theSerialIsReadFromTheReply() {
        assertEquals("IAQEB2502ABCDE", LunaDeviceIdentity.serial(options("IAQEB2502ABCDE")))
        assertNull(LunaDeviceIdentity.serial(options(null)))
    }
}
