package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * OPENZCINE-ANDROID-5: a Java exception thrown under a USB endpoint call (an OEM
 * `bulkTransfer` throwing `NegativeArraySizeException`) returned into native code and
 * killed the app. What Swift sees must be the transport's ordinary failure values instead.
 */
class UsbPtpTransportContainmentTest {
    private class ThrowingTransport : UsbPtpTransport {
        var closes = 0

        override fun writeBulk(bytes: ByteArray, timeoutMillis: Int): Int = throw IllegalStateException("write")

        override fun readBulk(maxBytes: Int, timeoutMillis: Int): ByteArray? = throw NegativeArraySizeException("-1")

        override fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray? = throw IllegalStateException("event")

        override fun isClosed(): Boolean = throw IllegalStateException("closed")

        override fun close() {
            closes++
            throw IllegalStateException("close")
        }
    }

    private class HealthyTransport : UsbPtpTransport {
        var closed = false

        override fun writeBulk(bytes: ByteArray, timeoutMillis: Int): Int = bytes.size

        override fun readBulk(maxBytes: Int, timeoutMillis: Int): ByteArray? = byteArrayOf(1, 2)

        override fun readEvent(maxBytes: Int, timeoutMillis: Int): ByteArray? = ByteArray(0)

        override fun isClosed(): Boolean = closed

        override fun close() {
            closed = true
        }
    }

    @Test
    fun `a throwing endpoint call becomes the transport's failure value`() {
        val raw = ThrowingTransport()
        val transport = raw.containingThrows()

        assertTrue(transport.writeBulk(byteArrayOf(1), 100) < 0)
        assertNull(transport.readBulk(512, 100))
        assertNull(transport.readEvent(64, 100))
        // A transport that cannot say whether it is open is treated as closed.
        assertTrue(transport.isClosed())
        transport.close()
        assertEquals(1, raw.closes)
    }

    @Test
    fun `a healthy transport passes through unchanged`() {
        val raw = HealthyTransport()
        val transport = raw.containingThrows()

        assertEquals(3, transport.writeBulk(byteArrayOf(1, 2, 3), 100))
        assertContentEquals(byteArrayOf(1, 2), transport.readBulk(512, 100))
        assertContentEquals(ByteArray(0), transport.readEvent(64, 100))
        assertFalse(transport.isClosed())
        transport.close()
        assertTrue(raw.closed)
        assertTrue(transport.isClosed())
    }
}
