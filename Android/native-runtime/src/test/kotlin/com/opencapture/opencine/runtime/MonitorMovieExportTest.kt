package com.opencapture.opencine.runtime

import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.FileTime
import kotlin.io.path.createTempDirectory
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class MonitorMovieExportTest {
    private val errors = MonitorMovieExportErrorFactory { reason, _ -> IllegalStateException(reason.name) }
    private fun lut() = MonitorMovieExportLut("Fixture look", 2, ByteArray(32))

    private class Codec(val completion: MonitorMovieCodecCompletion) : MonitorMovieCodec {
        var starts = 0
        var cancellations = 0
        var progress: Int? = null
        override fun start() { starts++ }
        override fun progressPercent() = progress
        override fun cancel() { cancellations++ }
    }

    @Test fun unknownProgressStaysAbsentAndKnownZeroIsReportedBeforeNativeCompletion() = runTest {
        val root = createTempDirectory("movie-progress")
        try {
            val calls = mutableListOf<Codec>()
            val owner = MonitorNativeMovieExporter(MonitorMovieCodecFactory { _, _, _, done -> Codec(done).also(calls::add) }, errors,
                StandardTestDispatcher(testScheduler), progressPollMillis = 10, nanoClock = { testScheduler.currentTime * 1_000_000 })
            val values = mutableListOf<Double>()
            val job = launch { owner.export(root.resolve("source"), root.resolve("target"), lut()) { values += it } }
            runCurrent()
            assertEquals(1, calls.single().starts)
            assertTrue(values.isEmpty())
            calls.single().progress = 0
            advanceTimeBy(10); runCurrent()
            assertEquals(listOf(0.0), values)
            calls.single().progress = 50
            advanceTimeBy(10); runCurrent()
            assertEquals(listOf(0.0, 0.5), values)
            calls.single().completion.completed()
            runCurrent()
            assertEquals(listOf(0.0, 0.5, 1.0), values)
            assertFalse(job.isActive)
            assertEquals(0, calls.single().cancellations)
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun lateCompletionOfCanceledCodecCannotCompleteSuccessorExport() = runTest {
        val root = createTempDirectory("movie-replacement")
        try {
            val calls = mutableListOf<Codec>()
            val owner = MonitorNativeMovieExporter(MonitorMovieCodecFactory { _, _, _, done -> Codec(done).also(calls::add) }, errors,
                StandardTestDispatcher(testScheduler), nanoClock = { testScheduler.currentTime * 1_000_000 })
            val first = launch { owner.export(root.resolve("source"), root.resolve("first"), lut()) {} }
            runCurrent(); first.cancelAndJoin()
            assertEquals(1, calls[0].cancellations)
            val values = mutableListOf<Double>()
            val second = launch { owner.export(root.resolve("source"), root.resolve("second"), lut()) { values += it } }
            runCurrent(); calls[0].completion.completed(); runCurrent()
            assertTrue(second.isActive)
            assertTrue(values.isEmpty())
            calls[1].completion.completed(); runCurrent()
            assertFalse(second.isActive)
            assertEquals(listOf(1.0), values)
            assertEquals(0, calls[1].cancellations)
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun repeatedOrRegressingProgressDoesNotExtendCodecStallDeadline() = runTest {
        val root = createTempDirectory("movie-stall")
        try {
            lateinit var codec: Codec
            val owner = MonitorNativeMovieExporter(MonitorMovieCodecFactory { _, _, _, done -> Codec(done).also { codec = it; it.progress = 5 } }, errors,
                StandardTestDispatcher(testScheduler), progressPollMillis = 10, stallTimeoutMillis = 100,
                nanoClock = { testScheduler.currentTime * 1_000_000 })
            val result = async { runCatching { owner.export(root.resolve("source"), root.resolve("target"), lut()) {} } }
            runCurrent(); advanceTimeBy(50); runCurrent()
            codec.progress = 2
            advanceTimeBy(50); runCurrent()
            assertEquals("CODEC_STALLED", result.await().exceptionOrNull()?.message)
            assertEquals(1, codec.cancellations)
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun passthroughDoesNotResolveLutExportCreateDirectoryOrPrune() = runTest {
        val root = createTempDirectory("movie-original")
        try {
            val original = root.resolve("clip.mov"); Files.write(original, byteArrayOf(1, 2, 3))
            val cache = root.resolve("exports")
            val owner = MonitorMovieExportPreparer(cache, object : MonitorLutMovieExporter {
                override suspend fun export(source: Path, target: Path, lut: MonitorMovieExportLut, onProgress: suspend (Double) -> Unit) { error("unexpected codec") }
            }, errors, ioDispatcher = StandardTestDispatcher(testScheduler))
            val result = owner.prepare(MonitorMovieExportInput(original, "clip.mov", "video/quicktime", 3, false), false,
                MonitorMovieExportContainer.MOV, { error("unexpected LUT") }, { error("unexpected progress") })
            assertSame(original, result.file)
            assertEquals(3L, result.byteCount)
            assertEquals(null, result.appliedLutName)
            assertEquals(null, result.transientExport)
            assertFalse(Files.exists(cache))
            owner.release(result)
            assertTrue(Files.readAllBytes(original).contentEquals(byteArrayOf(1, 2, 3)))
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun incompleteExportCleanupIsSuppressedOnOriginalCancellation() = runTest {
        val root = createTempDirectory("movie-cleanup")
        try {
            val canceled = CancellationException("fixture operator cancel")
            val original = root.resolve("source.mp4"); Files.write(original, byteArrayOf(42))
            var target: Path? = null
            val owner = MonitorMovieExportPreparer(root.resolve("exports"), object : MonitorLutMovieExporter {
                override suspend fun export(source: Path, output: Path, lut: MonitorMovieExportLut, onProgress: suspend (Double) -> Unit) {
                    target = output; Files.write(output, byteArrayOf(1)); throw canceled
                }
            }, errors, ioDispatcher = StandardTestDispatcher(testScheduler), deleteExport = { false })
            val failure = runCatching { owner.prepare(MonitorMovieExportInput(original, "source.mp4", "video/mp4", 1, true), true,
                MonitorMovieExportContainer.MOV, { lut() }, {}) }.exceptionOrNull()
            assertSame(canceled, failure)
            assertEquals(listOf("INCOMPLETE_CLEANUP"), canceled.suppressedExceptions.map { it.message })
            assertTrue(Files.isRegularFile(target))
            assertTrue(Files.readAllBytes(original).contentEquals(byteArrayOf(42)))
        } finally { root.toFile().deleteRecursively() }
    }

    @Test fun movFinalizationChangesOnlyTwoBrandsAndPruneKeepsForeignProtectedAndLinkEntries() {
        val root = createTempDirectory("movie-files")
        try {
            val path = root.resolve("movie-00000000-0000-0000-0000-000000000001.mov")
            val bytes = ByteBuffer.allocate(28).putInt(20).put("ftyp".toByteArray()).put("isom".toByteArray()).putInt(0).put("isom".toByteArray()).putLong(37).array()
            Files.write(path, bytes)
            finalizeMovieExportContainer(path, MonitorMovieExportContainer.MOV, errors)
            val expected = bytes.clone(); "qt  ".toByteArray().copyInto(expected, 8); "qt  ".toByteArray().copyInto(expected, 16)
            assertTrue(expected.contentEquals(Files.readAllBytes(path)))
            val foreign = root.resolve("foreign.mov"); Files.write(foreign, byteArrayOf(2))
            val protected = root.resolve("movie-00000000-0000-0000-0000-000000000002.mp4"); Files.write(protected, byteArrayOf(3))
            val link = root.resolve("movie-00000000-0000-0000-0000-000000000003.mov"); Files.createSymbolicLink(link, foreign)
            Files.setLastModifiedTime(path, FileTime.fromMillis(0)); Files.setLastModifiedTime(protected, FileTime.fromMillis(0))
            pruneOwnedMovieExports(root, setOf(protected), nowEpochMillis = 2_000, maximumAgeMillis = 1_000, maximumBytes = 0)
            assertFalse(Files.exists(path))
            assertTrue(Files.isRegularFile(foreign))
            assertTrue(Files.isRegularFile(protected))
            assertTrue(Files.isSymbolicLink(link))
        } finally { root.toFile().deleteRecursively() }
    }
}
