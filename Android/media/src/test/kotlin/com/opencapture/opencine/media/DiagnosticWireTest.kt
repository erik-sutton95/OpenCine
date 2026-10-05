package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class DiagnosticWireTest {
    @Test
    fun formatsAndReadsTheWireValues() {
        assertEquals("1970-01-02T03:04:05Z", DiagnosticWire.isoSeconds(97_445_678L))
        assertEquals(97_445_000L, DiagnosticWire.parseIsoSeconds("1970-01-02T03:04:05Z"))
        assertNull(DiagnosticWire.parseIsoSeconds("yesterday"))
        assertEquals("1970-01-02T03:04:05.678Z", DiagnosticWire.isoMillis(97_445_678L))
        assertEquals(10_000L, DiagnosticWire.parseHttpDate("Thu, 01 Jan 1970 00:00:10 GMT"))
        assertNull(DiagnosticWire.parseHttpDate("Thu, 32 Jan 1970 00:00:10 GMT"))

        val dsn = DiagnosticWire.uri("https://key@o0.ingest.sentry.io/prefix/42")
        assertEquals(DiagnosticWire.Address("https", "o0.ingest.sentry.io", "key", "/prefix/42", null, null), dsn)
        assertNull(DiagnosticWire.uri("https://bad host/"))
        assertEquals("HTTPS".lowercase(), DiagnosticWire.url("HTTPS://Example.com/x")?.scheme)
        assertNull(DiagnosticWire.url("no-scheme"))
    }
}
