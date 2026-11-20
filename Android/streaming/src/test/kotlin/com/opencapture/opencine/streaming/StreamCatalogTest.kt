package com.opencapture.opencine.streaming

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class StreamCatalogTest {
    private val native = FakeStreamingNative()
    private val catalog = StreamCatalog(native)

    @Test
    fun presetsDecodeWithCustomLast() {
        val presets = catalog.presets()
        assertEquals(listOf("twitch", "instagram", "custom"), presets.map { it.id })
        assertEquals("rtmps://ingest.example/app", presets[0].serverUrl)
        assertEquals(6_000_000, presets[0].maxVideoBitrateBps)
        assertTrue(presets[1].portrait && presets[1].requiresServerEntry)
        assertNull(presets[2].serverUrl)
        assertNull(presets[2].maxVideoBitrateBps)
        assertTrue(presets[2].allowsPlainRtmp)
        assertTrue(presets.dropLast(1).none { it.allowsPlainRtmp })
    }

    @Test
    fun formatRoundTripsThroughJson() {
        val format = catalog.format("twitch", 1280, 720, 30, 1)!!
        assertEquals(1280, format.width)
        assertEquals(30.0, format.framesPerSecond)
        assertEquals(format, StreamOutputFormat.fromJson(format.toJson()))
        assertNull(catalog.format("unknown", 1280, 720, null, null))
    }

    @Test
    fun destinationProblemsMapFromTheWire() {
        assertEquals(StreamDestinationCheck.Ok(encrypted = true), catalog.check("custom", "rtmps://h/a", "k"))
        assertEquals(StreamDestinationCheck.Ok(encrypted = false), catalog.check("custom", "rtmp://h/a", "k"))
        assertEquals(
            StreamDestinationCheck.Invalid(StreamDestinationProblem.EMPTY_KEY), catalog.check("custom", "rtmps://h/a", " "),
        )
        val wire = mapOf(
            "notRTMPS" to StreamDestinationProblem.NOT_RTMPS,
            "invalidServerURL" to StreamDestinationProblem.INVALID_SERVER_URL,
            "emptyKey" to StreamDestinationProblem.EMPTY_KEY,
            "keyLooksLikeURL" to StreamDestinationProblem.KEY_LOOKS_LIKE_URL,
            "invalidFormat" to StreamDestinationProblem.INVALID_FORMAT,
            "unknownPreset" to StreamDestinationProblem.UNKNOWN_PRESET,
            "somethingNew" to StreamDestinationProblem.INVALID_SERVER_URL,
        )
        for ((name, problem) in wire) {
            assertEquals(StreamDestinationCheck.Invalid(problem), StreamCatalog.parseCheck("""{"error":"$name"}"""))
        }
        assertEquals(
            StreamDestinationCheck.Invalid(StreamDestinationProblem.INVALID_SERVER_URL),
            StreamCatalog.parseCheck("not json"),
        )
    }

    @Test
    fun cameraWiFiAndUnknownRoutesCannotStream() {
        assertTrue(catalog.canStream(StreamConnectionRoute.SHARED_WIFI))
        assertFalse(catalog.canStream(StreamConnectionRoute.CAMERA_WIFI))
        assertFalse(catalog.canStream(null))
    }
}
