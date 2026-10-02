package com.opencapture.opencine.nikon

import java.io.Closeable

/** Raw USB byte transport consumed by the Swift PTP USB adapter over JNI. */
public interface UsbPtpTransport : Closeable {
    /** Writes one already-framed PTP USB container; returns the byte count or a negative failure. */
    public fun writeBulk(bytes: ByteArray, timeoutMillis: Int): Int

    /** Reads raw bulk bytes; empty means timeout and null means a closed or failed link. */
    public fun readBulk(maxBytes: Int, timeoutMillis: Int): ByteArray?

    /** Reads raw interrupt-event bytes; empty means timeout and null means a closed or failed link. */
    public fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray?

    /** Whether this transport was closed locally or by an attach/detach lifecycle event. */
    public fun isClosed(): Boolean
}

/**
 * Re-claims a USB PTP interface after the previous transport closed.
 *
 * Monitor recovery reconnects through the same session object. USB events share
 * that claimed interface, so an interrupt failure closes it; the next connect
 * must open a new one instead of handing JNI a dead handle.
 */
public fun interface UsbPtpTransportReopener {
    /** Opens a fresh transport, or a closed diagnostic reason the camera cannot be claimed. */
    public fun reopen(): UsbPtpOpenResult
}

/** Result of opening a platform-owned USB transport for the Swift facade. */
public sealed interface UsbPtpOpenResult {
    /** A permissioned connection with a stable saved-record host key. */
    public data class Opened(
        public val transport: UsbPtpTransport,
        /** Internal local reconnect key; never an operator-facing value. */
        public val hostKey: String,
        public val displayName: String,
    ) : UsbPtpOpenResult

    /** The requested camera was no longer available for a safe connection. */
    public data class Rejected(
        public val message: String,
        /** Closed diagnostic token; never a device path, serial, or exception text. */
        public val diagnosticPhase: String = "failed.usb",
    ) : UsbPtpOpenResult
}
