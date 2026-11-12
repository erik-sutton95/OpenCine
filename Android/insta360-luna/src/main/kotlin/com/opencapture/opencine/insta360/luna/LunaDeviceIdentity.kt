package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase

/**
 * Which camera a link reached, from its device-information read: option 48 (model), 15 (serial)
 * and 30 (firmware), Swift `LunaProtocol.deviceInformationRequest(includeSerial: true)`.
 */
internal object LunaDeviceIdentity {
    /** The GET_OPTIONS body (command 8) for model, serial and firmware. */
    val request: ByteArray = LunaWire.options(48, 15, 30)

    /** The serial in a device-information reply's options; null when the camera sent none. */
    fun serial(options: ByteArray): String? = LunaWire.text(options, 15).takeIf { it.isNotEmpty() }

    /**
     * Swift `openControl`: a link whose serial is not the one Bluetooth read reached a different
     * camera. Null when [expectedSerial] is unknown (saved Wi-Fi without Bluetooth) or matches.
     */
    fun mismatch(options: ByteArray, expectedSerial: String?): ConnectionFailure? =
        if (expectedSerial == null || serial(options) == expectedSerial) null
        else LunaFailures.failure(
            ConnectionFailure.Reason.WrongCamera, "wifi.serial-mismatch",
            "The Wi-Fi connection reached a different camera. Join the selected camera's network and retry.",
            CorePhase.NEGOTIATING,
        )

    /** Swift `authorizeOverBluetooth`: a Bluetooth read without a serial cannot verify the handoff. */
    val serialMissing: ConnectionFailure = LunaFailures.failure(
        ConnectionFailure.Reason.Other, "serial.missing",
        "The camera did not provide an identity to verify its Wi-Fi handoff.", CorePhase.NEGOTIATING,
    )
}
