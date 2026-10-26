package com.opencapture.opencine.gyro

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.UUID
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.json.JSONArray
import org.json.JSONObject

/**
 * The moved OpenZCine file store with the mount-moved sidecar and batch share list. Takes are
 * typed [GyroLogUpdate]s from `decodeLogReply`; statuses come from `resolveGyroTakeStatus`.
 */
class GyroLogStoreTest {
    private val root = Files.createTempDirectory("gyro-store-test").toFile()

    @AfterTest
    fun cleanup() {
        root.deleteRecursively()
    }

    @Test
    fun oneDamagedPartialPreservesSavedLogsAndOtherRecoverableFiles() {
        val native = RecoveryNative()
        val store = GyroLogStore(root, native)
        val saved = descriptor()
        val savedId = saved.getString("id")
        store.apply(
            listOf(
                opened(saved),
                appended(savedId, "valid gyro"),
                finished(summary(saved, "normal")),
            ),
        )
        val damaged = descriptor()
        File(root, "${damaged.getString("id")}.json").writeText(damaged.toString())
        File(root, "${damaged.getString("id")}.partial").writeBytes(byteArrayOf())
        val recoverable = descriptor()
        File(root, "${recoverable.getString("id")}.json").writeText(recoverable.toString())
        File(root, "${recoverable.getString("id")}.partial").writeText("valid gyro")

        assertFailsWith<IOException> { store.recover() }

        val entries = store.entries().associateBy { it.id }
        assertEquals(3, entries.size)
        val savedEntry = entries.getValue(savedId)
        assertTrue(savedEntry.canShare)
        assertEquals(GyroTakeStatus.Ready, savedEntry.status)
        assertEquals(GyroTakeStatus.CutShort, entries.getValue(recoverable.getString("id")).status)
        val incomplete = entries.getValue(damaged.getString("id"))
        assertFalse(incomplete.canShare)
        assertNull(incomplete.summary)
        assertEquals(GyroTakeStatus.CutShort, incomplete.status)
        assertTrue(File(root, "${damaged.getString("id")}.partial").exists())
        assertTrue(File(root, recoverable.getString("filename")).isFile)
        assertTrue(native.openRecoveries.isEmpty())
        store.delete(incomplete)
        assertFalse(File(root, "${incomplete.id}.partial").exists())
        assertFalse(File(root, "${incomplete.id}.json").exists())
        assertEquals(2, store.entries().size)
        assertEquals("valid gyro", savedEntry.file.readText())
    }

    @Test
    fun activeLogCannotBeDeletedAndFinalizedBytesAreRetained() {
        val store = GyroLogStore(root, RecoveryNative())
        val descriptor = descriptor()
        val id = descriptor.getString("id")
        store.apply(listOf(opened(descriptor)))
        val active = store.entries().single()
        assertTrue(active.active)
        assertFalse(active.canShare)
        assertTrue(active.isCalibrated)
        assertNull(active.durationSeconds)
        assertNull(active.measuredRate)
        assertNull(active.approximateStartOffset)
        assertEquals(GyroTakeStatus.Recording, active.status)
        assertFailsWith<IllegalStateException> { store.delete(active) }
        store.apply(
            listOf(appended(id, "valid gyro"), finished(summary(descriptor, "normal"))),
        )
        val entry = store.entries().single()
        assertFalse(entry.active)
        assertTrue(entry.canShare)
        assertTrue(entry.isCalibrated)
        assertEquals(GyroTakeStatus.Ready, entry.status)
        assertEquals(0.01, requireNotNull(entry.durationSeconds), 0.0)
        assertEquals(100.0, requireNotNull(entry.measuredRate), 0.0)
        assertEquals(2.0, requireNotNull(entry.approximateStartOffset), 0.0)
        assertEquals("valid gyro", entry.file.readText())
        store.delete(entry)
        assertTrue(store.entries().isEmpty())
    }

    @Test
    fun damagedFinalMetadataLeavesThatFileDeletableAndHealthyLogsShareable() {
        val store = GyroLogStore(root, RecoveryNative())
        val healthy = descriptor()
        val damaged = descriptor()
        for (descriptor in listOf(healthy, damaged)) {
            val id = descriptor.getString("id")
            File(root, "$id.json").writeText(descriptor.toString())
            File(root, descriptor.getString("filename")).writeText("valid gyro")
            File(root, "$id.summary.json").writeText(summary(descriptor, "normal").toString())
        }
        File(root, "${damaged.getString("id")}.summary.json").writeText("{broken")
        val entries = store.entries().associateBy { it.id }
        assertEquals(2, entries.size)
        assertTrue(entries.getValue(healthy.getString("id")).canShare)
        val incomplete = entries.getValue(damaged.getString("id"))
        assertFalse(incomplete.canShare)
        assertEquals(GyroTakeStatus.CutShort, incomplete.status)
        store.delete(incomplete)
        assertEquals(healthy.getString("id"), store.entries().single().id)
    }

    @Test
    fun failedAppendRecoveryKeepsOnlyPersistedCompleteRowsAndTheirStatistics() {
        val native = RecoveryNative()
        val store = GyroLogStore(root, native) { file, bytes ->
            file.write(bytes, 0, 12)
            throw IOException("Injected partial write")
        }
        val descriptor = descriptor()
        val id = descriptor.getString("id")
        val intendedSummary = summary(descriptor, "normal").put("sampleCount", 100)
        assertFailsWith<IOException> {
            store.apply(
                listOf(
                    opened(descriptor),
                    appended(id, "valid gyrotruncated row"),
                    finished(intendedSummary),
                ),
            )
        }
        store.abort()
        val recovered = store.entries().single()
        assertEquals("valid gyro", recovered.file.readText())
        assertEquals(2, requireNotNull(recovered.summary).getInt("sampleCount"))
        assertEquals(GyroTakeStatus.CutShort, recovered.status)
        assertTrue(recovered.canShare)
        assertFalse(recovered.active)
        assertTrue(native.openRecoveries.isEmpty())
    }

    @Test
    fun failedRecoveryAfterWriteErrorReleasesTheIncompleteFileForDeletion() {
        val native = RecoveryNative()
        val store = GyroLogStore(root, native) { file, _ ->
            file.write("bad header".toByteArray())
            throw IOException("Injected write failure")
        }
        val descriptor = descriptor()
        val id = descriptor.getString("id")
        assertFailsWith<IOException> {
            store.apply(listOf(opened(descriptor), appended(id, "valid gyro")))
        }
        assertFailsWith<IOException> { store.abort() }
        val incomplete = store.entries().single()
        assertFalse(incomplete.active)
        assertFalse(incomplete.canShare)
        assertEquals(GyroTakeStatus.CutShort, incomplete.status)
        assertEquals("bad header", incomplete.file.readText())
        assertTrue(native.openRecoveries.isEmpty())
        store.delete(incomplete)
        assertTrue(store.entries().isEmpty())
    }

    @Test
    fun mountMovedSidecarSurvivesRecovery() {
        val native = RecoveryNative()
        val store = GyroLogStore(root, native)
        val descriptor = descriptor()
        val id = descriptor.getString("id")
        store.apply(
            listOf(
                opened(descriptor),
                appended(id, "valid gyro"),
                mountMoved(id, 1.25),
            ),
        )
        assertEquals(
            1.25,
            JSONObject(File(root, "$id.mount-moved.json").readText()).getDouble("offsetSeconds"),
            0.0,
        )
        store.close()

        val replacement = GyroLogStore(root, native)
        replacement.recover()

        assertEquals(1.25, native.mountMovedOffset ?: Double.NaN, 0.0)
        val entry = replacement.entries().single()
        assertEquals(1.25, requireNotNull(entry.summary).getDouble("mountMovedOffset"), 0.0)
        assertEquals(GyroTakeStatus.MountMoved(1.25), entry.status)
        assertFalse(File(root, "$id.mount-moved.json").exists())
    }

    @Test
    fun mountMovedSidecarIsMergedOnFinish() {
        val store = GyroLogStore(root, RecoveryNative())
        val descriptor = descriptor()
        val id = descriptor.getString("id")
        store.apply(
            listOf(
                opened(descriptor),
                appended(id, "valid gyro"),
                mountMoved(id, 2.5),
                finished(summary(descriptor, "normal")),
            ),
        )
        val entry = store.entries().single()
        assertEquals(2.5, requireNotNull(entry.summary).getDouble("mountMovedOffset"), 0.0)
        assertEquals(GyroTakeStatus.MountMoved(2.5), entry.status)
        assertEquals("valid gyro", entry.file.readText())
        assertFalse(File(root, "$id.mount-moved.json").exists())
    }

    @Test
    fun shareFilesRefusesActiveTakes() {
        val store = GyroLogStore(root, RecoveryNative())
        val active = descriptor()
        val activeId = active.getString("id")
        store.apply(listOf(opened(active), appended(activeId, "valid gyro")))
        assertFailsWith<IllegalStateException> { store.shareFiles(listOf(activeId)) }
        store.apply(listOf(finished(summary(active, "normal"))))

        val second = descriptor()
        val secondId = second.getString("id")
        store.apply(
            listOf(
                opened(second),
                appended(secondId, "valid gyro"),
                finished(summary(second, "normal")),
            ),
        )
        assertEquals(
            listOf("$secondId.gcsv", "$activeId.gcsv"),
            store.shareFiles(listOf(secondId, activeId)).map { it.name },
        )

        val unfinished = descriptor()
        val unfinishedId = unfinished.getString("id")
        store.apply(listOf(opened(unfinished), appended(unfinishedId, "valid gyro")))
        store.close()
        val inactive = store.entries().single { it.id == unfinishedId }
        assertFalse(inactive.active)
        assertNull(inactive.summary)
        assertFailsWith<IllegalStateException> { store.shareFiles(listOf(unfinishedId)) }
        assertFailsWith<IllegalArgumentException> {
            store.shareFiles(listOf(UUID.randomUUID().toString()))
        }
    }

    @Test
    fun legacyLayoutLoadsInPlace() {
        val descriptor = descriptor()
        val id = descriptor.getString("id")
        val filename = "OpenZCine-${UUID.randomUUID()}.gcsv"
        descriptor.put("filename", filename)
        File(root, "$id.json").writeText(descriptor.toString())
        File(root, "$id.summary.json").writeText(summary(descriptor, "normal").toString())
        File(root, filename).writeText("legacy rows")

        val entry = GyroLogStore(root, RecoveryNative()).entries().single()

        assertEquals(id, entry.id)
        assertEquals(filename, entry.file.name)
        assertEquals("legacy rows", entry.file.readText())
        assertTrue(entry.canShare)
        assertEquals(GyroTakeStatus.Ready, entry.status)
    }

    private fun descriptor(): JSONObject {
        val id = UUID.randomUUID().toString().uppercase()
        return JSONObject()
            .put("id", id)
            .put("cameraLabel", "Test camera")
            .put("startDate", 123_000)
            .put("filename", "$id.gcsv")
            .put("approximateStartOffset", 2.0)
            .put("isPartial", false)
            .put(
                "mountCalibration",
                JSONObject()
                    .put("rotation", JSONArray())
                    .put("validationErrorDegrees", 1.5)
                    .put("separationDegrees", 60),
            )
    }

    private fun summary(descriptor: JSONObject, reason: String): JSONObject =
        JSONObject()
            .put("descriptor", descriptor)
            .put("sampleCount", 2)
            .put("duration", 0.01)
            .put("measuredRate", 100)
            .put("largestGap", 0.01)
            .put("rejectedSampleCount", 0)
            .put("approximateStartOffset", 2.0)
            .put("termination", reason)
            .put("isPartial", reason != "normal")

    private fun opened(descriptor: JSONObject) = GyroLogUpdate.Opened(descriptor)

    private fun appended(id: String, text: String) =
        GyroLogUpdate.Appended(id, text.toByteArray())

    private fun mountMoved(id: String, offsetSeconds: Double) =
        GyroLogUpdate.MountMoved(id, offsetSeconds)

    private fun finished(summary: JSONObject) = GyroLogUpdate.Finished(summary)

    private inner class RecoveryNative : TestGyroNativeApi() {
        val openRecoveries = mutableMapOf<String, Boolean>()
        var mountMovedOffset: Double? = null

        override fun recoveryCreate(): String =
            UUID.randomUUID().toString().also { openRecoveries[it] = false }

        override fun recoveryAccept(owner: String, bytes: ByteArray): Long {
            openRecoveries[owner] = bytes.toString(Charsets.UTF_8).startsWith("valid gyro")
            return if (openRecoveries[owner] == true) "valid gyro".length.toLong() else -1
        }

        override fun recoveryFinish(
            owner: String,
            descriptorJSON: String,
            mountMovedOffset: Double,
        ): String? {
            this.mountMovedOffset = mountMovedOffset
            return if (openRecoveries.remove(owner) == true) {
                summary(JSONObject(descriptorJSON), "recovered").toString()
            } else {
                null
            }
        }
    }
}
