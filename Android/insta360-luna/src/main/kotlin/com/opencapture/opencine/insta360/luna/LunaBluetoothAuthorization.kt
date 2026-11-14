package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.ConnectionPhase
import kotlinx.coroutines.withTimeoutOrNull

/** The camera is no Luna Ultra this integration supports, or its encrypted identity did not match. */
internal class LunaUnsupportedCamera(message: String) : IllegalStateException(message)

/**
 * The Bluetooth authorization a connect and a return to the access point share (Swift twin
 * `LunaBluetoothAuthorization`): the camera's identity, the encrypted session, this phone's approval
 * and the encrypted credential read, in the hardware-verified order. Every request goes through
 * [request], so a test sees each one the camera would receive.
 */
internal class LunaBluetoothAuthorization(
    /** One request on the Bluetooth link: its code, body and encryption; returns the camera's 200 body. */
    val request: suspend (code: Int, body: ByteArray, encrypted: Boolean) -> ByteArray,
    /** The session key the exchange agreed; encrypted requests use it from then on. */
    private val agreed: (ByteArray) -> Unit,
    /** The next approval notification (8209 or 8228) the camera sends. */
    private val approvals: suspend () -> LunaWire.Message,
    /** The connect phase each step starts; a return to the access point reports none. */
    private val phase: (ConnectionPhase) -> Unit = {},
    /** The camera's firmware once Bluetooth read its identity. */
    private val identified: (firmware: String) -> Unit = {},
) {
    /**
     * The serial Bluetooth read and the credential read's reply. A camera that does not approve this
     * phone throws [LunaNotApproved]; one that is no supported Luna throws [LunaUnsupportedCamera].
     */
    suspend fun run(authBody: ByteArray): Pair<String, ByteArray> {
        val initial = LunaWire.bytes(request(8, LunaDeviceIdentity.request, false), 2)
        if (LunaWire.text(initial, 48) != MODEL) throw LunaUnsupportedCamera("Unexpected camera model")
        val serial = LunaDeviceIdentity.serial(initial) ?: throw LunaStationFailure(LunaDeviceIdentity.serialMissing)
        identified(LunaWire.text(initial, 30))
        phase(ConnectionPhase.PAIRING)
        val schemes = LunaWire.schemes(request(240, ByteArray(0), false))
        if (3L !in schemes) throw LunaUnsupportedCamera("AES-GCM is not supported")
        val pair = LunaWire.keyPair()
        agreed(LunaWire.exchange(pair, request(241, LunaWire.integer(1, 3) + LunaWire.blob(2, LunaWire.publicBytes(pair)), false)))
        val verified = LunaWire.bytes(request(8, LunaWire.options(48, 30), true), 2)
        if (LunaWire.text(verified, 48) != MODEL) throw LunaUnsupportedCamera("The encrypted camera identity did not match")
        when (LunaWire.number(request(39, authBody, false), 1)) {
            0L -> Unit
            1L -> {
                phase(ConnectionPhase.AWAITING_APPROVAL)
                request(86, LunaWire.integer(1, 1), false)
                var approved: Boolean? = null
                withTimeoutOrNull(120_000) {
                    while (approved == null) {
                        val approval = approvals()
                        if (LunaWire.number(approval.body, 2) in 0L..1L) approved = LunaWire.number(approval.body, 1) == 0L
                    }
                }
                if (approved != true) throw LunaNotApproved("Camera did not approve this client")
            }
            else -> throw LunaNotApproved("Unknown camera authorization result")
        }
        phase(ConnectionPhase.READING_WIFI_CREDS)
        return serial to request(8, LunaWire.options(36, 37, 43), true)
    }

    private companion object {
        const val MODEL = "Insta360 Luna Ultra"
    }
}
