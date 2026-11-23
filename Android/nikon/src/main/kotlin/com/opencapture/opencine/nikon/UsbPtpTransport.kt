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

/**
 * The [UsbPtpTransport] handed to Swift over JNI. Its callers are native code: a Java exception
 * thrown under an endpoint call (an OEM `bulkTransfer` has thrown `NegativeArraySizeException`,
 * OPENZCINE-ANDROID-5) would come back to Swift still pending and end the process when the
 * thread detaches. Each call here returns the transport's ordinary failure value instead:
 * a negative write count, a null read, closed when the state cannot be read.
 */
internal fun UsbPtpTransport.containingThrows(): UsbPtpTransport =
    this as? ThrowContainingUsbPtpTransport ?: ThrowContainingUsbPtpTransport(this)

private class ThrowContainingUsbPtpTransport(private val transport: UsbPtpTransport) : UsbPtpTransport {
    override fun writeBulk(bytes: ByteArray, timeoutMillis: Int): Int =
        try {
            transport.writeBulk(bytes, timeoutMillis)
        } catch (_: Exception) {
            -1
        }

    override fun readBulk(maxBytes: Int, timeoutMillis: Int): ByteArray? =
        try {
            transport.readBulk(maxBytes, timeoutMillis)
        } catch (_: Exception) {
            null
        }

    override fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray? =
        try {
            transport.readEvent(maxBytes, timeoutMillis)
        } catch (_: Exception) {
            null
        }

    override fun isClosed(): Boolean =
        try {
            transport.isClosed()
        } catch (_: Exception) {
            true
        }

    override fun close() {
        try {
            transport.close()
        } catch (_: Exception) {
            // Closing is best effort; the claim is released with the connection either way.
        }
    }
}
