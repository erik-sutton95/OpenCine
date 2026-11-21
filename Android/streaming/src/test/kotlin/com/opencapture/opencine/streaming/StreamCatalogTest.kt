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
    fun formatPassesTheQualityChoiceToTheEngine() {
        val upscaled = catalog.format("twitch", 1280, 720, 30, 1, choice = StreamQualityChoice.UPSCALED_1080P)!!
        assertEquals(1920, upscaled.width)
        assertEquals("upscaled1080p", native.lastChoice)
        catalog.format("twitch", 1280, 720, 30, 1)
        assertEquals("cameraFeed", native.lastChoice)
    }

    @Test
    fun upscaledIsOfferedOnlyBelow1080() {
        val both = listOf(StreamQualityChoice.CAMERA_FEED, StreamQualityChoice.UPSCALED_1080P)
        assertEquals(both, StreamQualityChoice.offered(1280, 720))
        assertEquals(both, StreamQualityChoice.offered(1024, 768))
        assertEquals(both, StreamQualityChoice.offered(720, 1280))
        assertEquals(listOf(StreamQualityChoice.CAMERA_FEED), StreamQualityChoice.offered(1920, 1080))
        assertEquals(listOf(StreamQualityChoice.CAMERA_FEED), StreamQualityChoice.offered(null, null))
        assertEquals(StreamQualityChoice.UPSCALED_1080P, StreamQualityChoice.fromWire("upscaled1080p"))
        assertNull(StreamQualityChoice.fromWire("nope"))
    }

    @Test
    fun cameraChoiceComesFromTheHostNeverFromTheSourceSize() {
        assertEquals(StreamQualityChoice.CAMERA_1080P, StreamQualityChoice.fromWire("camera1080p"))
        for (size in listOf(1280 to 720, 1920 to 1080)) {
            assertFalse(StreamQualityChoice.CAMERA_1080P in StreamQualityChoice.offered(size.first, size.second))
        }
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
