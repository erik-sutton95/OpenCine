package com.opencapture.opencine.runtime

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.createTempDirectory
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The LUT-baked export must still carry the camera's start timecode: an NLE conforms the proxy to
 * its master through that track, and Media3's muxer writes video and audio only.
 *
 * The fixtures are hand-built ISO-BMFF files rather than encoder output so the exact bytes an NLE
 * reads, the frame-number sample, and every chunk offset that must survive the rewrite, are
 * asserted, not assumed.
 */
class MonitorMovieTimecodeTest {
    @Test
    fun `a baked export regains the source timecode sample, track reference, and video data`() {
        withFiles { source, target ->
            Files.write(source, cameraProxy())
            Files.write(target, bakedExport(moovLast = true))

            assertTrue(MonitorMovieTimecode.copyTimecodeTrack(source, target))

            val written = Files.readAllBytes(target)
            assertContentEquals(TIMECODE_SAMPLE, written.timecodeSample())
            // The video track's own bytes must still be exactly where its chunk offset says.
            assertContentEquals(VIDEO_SAMPLE, written.videoSample())
            assertEquals(TIMECODE_TRACK_ID, written.videoTimecodeReference())
            assertEquals(TIMECODE_TRACK_ID + 1, written.nextTrackID())
        }
    }

    @Test
    fun `a camera timecode track without an edit list is copied too`() {
        withFiles { source, target ->
            Files.write(source, mp4(moovLast = true, withTimecode = true, edits = false))
            Files.write(target, mp4(moovLast = true, withTimecode = false, edits = false))

            assertTrue(MonitorMovieTimecode.copyTimecodeTrack(source, target))

            val written = Files.readAllBytes(target)
            assertContentEquals(TIMECODE_SAMPLE, written.timecodeSample())
            assertContentEquals(VIDEO_SAMPLE, written.videoSample())
            assertEquals(TIMECODE_TRACK_ID, written.videoTimecodeReference())
        }
    }

    @Test
    fun `a streamable export whose header precedes the media keeps every chunk offset valid`() {
        withFiles { source, target ->
            Files.write(source, cameraProxy())
            Files.write(target, bakedExport(moovLast = false))

            assertTrue(MonitorMovieTimecode.copyTimecodeTrack(source, target))

            val written = Files.readAllBytes(target)
            assertContentEquals(VIDEO_SAMPLE, written.videoSample())
            assertContentEquals(TIMECODE_SAMPLE, written.timecodeSample())
        }
    }

    @Test
    fun `the copied track keeps its length in an export with another movie timescale`() {
        withFiles { source, target ->
            Files.write(source, cameraProxy())
            Files.write(target, mp4(moovLast = true, withTimecode = false, movieTimescale = EXPORT_MOVIE_TIMESCALE))

            assertTrue(MonitorMovieTimecode.copyTimecodeTrack(source, target))

            val written = Files.readAllBytes(target)
            // Two seconds in the export's movie timescale, in the header and in the edit list alike.
            assertEquals(EXPORT_MOVIE_TIMESCALE * 2, written.timecodeTrackDuration())
            assertEquals(EXPORT_MOVIE_TIMESCALE * 2, written.timecodeEditDuration())
            assertContentEquals(TIMECODE_SAMPLE, written.timecodeSample())
        }
    }

    @Test
    fun `a source without a timecode track leaves the export byte-identical`() {
        withFiles { source, target ->
            Files.write(source, bakedExport(moovLast = true))
            val exported = bakedExport(moovLast = true)
            Files.write(target, exported)

            assertFalse(MonitorMovieTimecode.copyTimecodeTrack(source, target))

            assertContentEquals(exported, Files.readAllBytes(target))
        }
    }

    @Test
    fun `an export that already carries timecode is not given a second track`() {
        withFiles { source, target ->
            Files.write(source, cameraProxy())
            Files.write(target, cameraProxy())

            assertFalse(MonitorMovieTimecode.copyTimecodeTrack(source, target))
        }
    }

    // MARK: - Fixtures

    /** ftyp + mdat(video, timecode) + moov(video track, timecode track). */
    private fun cameraProxy(): ByteArray = mp4(moovLast = true, withTimecode = true)

    /** Transformer output: video only, header either trailing (MediaMuxer) or leading (faststart). */
    private fun bakedExport(moovLast: Boolean): ByteArray = mp4(moovLast, withTimecode = false)

    private fun mp4(
        moovLast: Boolean,
        withTimecode: Boolean,
        movieTimescale: Int = MOVIE_TIMESCALE,
        edits: Boolean = true,
    ): ByteArray {
        val ftyp = box("ftyp", "isom".ascii() + intBytes(512) + "isomiso2".ascii())
        val mediaPayload =
            if (withTimecode) VIDEO_SAMPLE + TIMECODE_SAMPLE else VIDEO_SAMPLE
        val mdat = box("mdat", mediaPayload)
        // Two layouts, one header size: build the moov with placeholder offsets, then place it.
        fun assemble(videoOffset: Int, timecodeOffset: Int): ByteArray {
            val tracks =
                trak(VIDEO_TRACK_ID, "vide", VIDEO_SAMPLE.size, videoOffset, movieTimescale, edits) +
                    if (withTimecode) {
                        trak(TIMECODE_TRACK_ID, "tmcd", TIMECODE_SAMPLE.size, timecodeOffset, movieTimescale, edits)
                    } else {
                        ByteArray(0)
                    }
            return box("moov", mvhd(movieTimescale) + tracks)
        }

        val moovSize = assemble(0, 0).size
        return if (moovLast) {
            val mdatStart = ftyp.size
            val moov = assemble(mdatStart + 8, mdatStart + 8 + VIDEO_SAMPLE.size)
            ftyp + mdat + moov
        } else {
            val mdatStart = ftyp.size + moovSize
            val moov = assemble(mdatStart + 8, mdatStart + 8 + VIDEO_SAMPLE.size)
            ftyp + moov + mdat
        }
    }

    private fun mvhd(movieTimescale: Int): ByteArray {
        val content = ByteArrayOutputStream()
        content.write(intBytes(0)) // version 0 + flags
        content.write(intBytes(0)) // creation
        content.write(intBytes(0)) // modification
        content.write(intBytes(movieTimescale))
        content.write(intBytes(movieTimescale * 2)) // duration
        content.write(intBytes(0x0001_0000)) // rate
        content.write(ByteArray(2 + 2 + 8)) // volume, reserved
        content.write(ByteArray(36)) // matrix
        content.write(ByteArray(24)) // pre-defined
        content.write(intBytes(VIDEO_TRACK_ID + 1)) // next track ID
        return box("mvhd", content.toByteArray())
    }

    private fun trak(
        trackID: Int,
        handler: String,
        sampleBytes: Int,
        chunkOffset: Int,
        movieTimescale: Int,
        edits: Boolean,
    ): ByteArray {
        val tkhd = ByteArrayOutputStream()
        tkhd.write(intBytes(0)) // version 0 + flags
        tkhd.write(intBytes(0)) // creation
        tkhd.write(intBytes(0)) // modification
        tkhd.write(intBytes(trackID))
        tkhd.write(intBytes(0)) // reserved
        tkhd.write(intBytes(movieTimescale * 2)) // duration
        tkhd.write(ByteArray(8 + 2 + 2 + 2 + 2 + 36 + 4 + 4))
        val hdlr =
            box("hdlr", intBytes(0) + intBytes(0) + handler.ascii() + ByteArray(12) + byteArrayOf(0))
        val stsz = box("stsz", intBytes(0) + intBytes(sampleBytes) + intBytes(1))
        val stco = box("stco", intBytes(0) + intBytes(1) + intBytes(chunkOffset))
        val stbl = box("stbl", box("stsd", intBytes(0) + intBytes(0)) + stsz + stco)
        val minf = box("minf", stbl)
        val mdia = box("mdia", hdlr + minf)
        // One edit spanning the track, its segment counted in the movie timescale.
        val elst = box("elst", intBytes(0) + intBytes(1) + intBytes(movieTimescale * 2) + intBytes(0) + intBytes(0x0001_0000))
        return box("trak", box("tkhd", tkhd.toByteArray()) + (if (edits) box("edts", elst) else ByteArray(0)) + mdia)
    }

    // MARK: - Independent reader

    private fun ByteArray.timecodeSample(): ByteArray = sampleFor("tmcd")

    private fun ByteArray.videoSample(): ByteArray = sampleFor("vide")

    private fun ByteArray.sampleFor(handler: String): ByteArray {
        val trak = assertNotNull(traks().firstOrNull { handlerOf(it) == handler })
        val stbl = assertNotNull(path(trak, "mdia", "minf", "stbl"))
        val stsz = assertNotNull(children(stbl).firstOrNull { it.type == "stsz" })
        val stco = assertNotNull(children(stbl).firstOrNull { it.type == "stco" })
        val sampleBytes = int(stsz.start + 8 + 4)
        val offset = int(stco.start + 8 + 8)
        return copyOfRange(offset, offset + sampleBytes)
    }

    /** Version 0 `tkhd`: flags, creation, modification, track ID and reserved precede it. */
    private fun ByteArray.timecodeTrackDuration(): Int {
        val tkhd = assertNotNull(children(timecodeTrak()).firstOrNull { it.type == "tkhd" })
        return int(tkhd.start + 8 + 20)
    }

    /** Version 0 `elst`: the first segment duration follows the flags and entry count. */
    private fun ByteArray.timecodeEditDuration(): Int {
        val elst = assertNotNull(path(timecodeTrak(), "edts", "elst"))
        return int(elst.start + 8 + 8)
    }

    private fun ByteArray.timecodeTrak(): TestBox = assertNotNull(traks().firstOrNull { handlerOf(it) == "tmcd" })

    private fun ByteArray.videoTimecodeReference(): Int {
        val trak = assertNotNull(traks().firstOrNull { handlerOf(it) == "vide" })
        val tref = assertNotNull(children(trak).firstOrNull { it.type == "tref" })
        val tmcd = assertNotNull(children(tref).firstOrNull { it.type == "tmcd" })
        return int(tmcd.start + 8)
    }

    private fun ByteArray.nextTrackID(): Int {
        val moov = assertNotNull(topLevel().firstOrNull { it.type == "moov" })
        val mvhd = assertNotNull(children(moov).firstOrNull { it.type == "mvhd" })
        return int(mvhd.start + mvhd.size - 4)
    }

    private fun ByteArray.traks(): List<TestBox> {
        val moov = assertNotNull(topLevel().firstOrNull { it.type == "moov" })
        return children(moov).filter { it.type == "trak" }
    }

    private fun ByteArray.handlerOf(trak: TestBox): String? =
        path(trak, "mdia", "hdlr")?.let { String(this, it.start + 8 + 8, 4, Charsets.US_ASCII) }

    private fun ByteArray.path(root: TestBox, vararg types: String): TestBox? {
        var current = root
        types.forEach { type ->
            current = children(current).firstOrNull { it.type == type } ?: return null
        }
        return current
    }

    private fun ByteArray.topLevel(): List<TestBox> = scan(0, size)

    private fun ByteArray.children(box: TestBox): List<TestBox> = scan(box.start + 8, box.start + box.size)

    private fun ByteArray.scan(from: Int, until: Int): List<TestBox> {
        val found = mutableListOf<TestBox>()
        var cursor = from
        while (cursor + 8 <= until) {
            val size = int(cursor)
            if (size < 8 || cursor + size > until) break
            found += TestBox(String(this, cursor + 4, 4, Charsets.US_ASCII), cursor, size)
            cursor += size
        }
        return found
    }

    private fun ByteArray.int(position: Int): Int =
        ByteBuffer.wrap(this, position, 4).order(ByteOrder.BIG_ENDIAN).int

    private data class TestBox(val type: String, val start: Int, val size: Int)

    private fun withFiles(block: (Path, Path) -> Unit) {
        val root = createTempDirectory("openzcine-timecode")
        try {
            block(root.resolve("source.mp4"), root.resolve("export.mp4"))
        } finally {
            root.toFile().deleteRecursively()
        }
    }

    private fun box(type: String, content: ByteArray): ByteArray =
        intBytes(8 + content.size) + type.ascii() + content

    private fun intBytes(value: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(value).array()

    private fun String.ascii(): ByteArray = toByteArray(Charsets.US_ASCII)

    private companion object {
        const val MOVIE_TIMESCALE = 1_000

        /** Media3's muxer writes its movie header at 10 kHz. */
        const val EXPORT_MOVIE_TIMESCALE = 10_000
        const val VIDEO_TRACK_ID = 1
        const val TIMECODE_TRACK_ID = 2
        val VIDEO_SAMPLE = ByteArray(64) { (it and 0x7F).toByte() }

        /** One 32-bit frame number: 01:00:00:00 at 24 fps. */
        val TIMECODE_SAMPLE = byteArrayOf(0x00, 0x01, 0x53, 0x00.toByte())
    }
}
