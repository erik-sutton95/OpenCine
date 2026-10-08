package com.opencapture.opencine.relay

/** Typed deployed control payloads over the common stream owner. */
public interface RelayControlWireCodec<State, Metadata, Command, Control, Denied> : RelayWireCodec<State, Metadata, Command> {
    public fun encodeControl(holderName: String, holderIsRecipient: Boolean): ByteArray
    public fun decodeControl(payload: ByteArray): Control
    public fun holderIsRecipient(control: Control): Boolean
    public fun encodeDenied(reason: String, passcodeRequired: Boolean): ByteArray
    public fun decodeDenied(payload: ByteArray): Denied
}

/** Immutable stream scheduling/admission facts, independent of schema and manufacturer. */
public data class RelaySocketPolicy(
    public val connectTimeoutMillis: Int = 8_000,
    public val receiveChunkBytes: Int = 256 * 1024,
    public val maximumControlQueue: Int = 32,
    public val courtesyCloseMillis: Long = 150,
    public val parkedLeaseMillis: Long = 20_000,
    public val requiresHostVersionMatch: Boolean = false,
    public val versionMismatchReason: String = "This broadcast uses an app version this device can't watch.",
    public val missingPasscodeReason: String = "This broadcast asks for a passcode.",
    public val wrongPasscodeReason: String = "That passcode doesn't match this broadcast.",
) {
    init {
        require(connectTimeoutMillis > 0 && receiveChunkBytes > 0 && maximumControlQueue > 0)
        require(courtesyCloseMillis >= 0 && parkedLeaseMillis > 0)
    }
}
