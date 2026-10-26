package com.opencapture.opencine.gyro

import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID
import org.json.JSONObject

/**
 * An app-private motion artifact; an open take is never shared or deleted. [status] comes from
 * the take's own facts through [resolveGyroTakeStatus].
 */
data class GyroLogEntry(
    val descriptor: JSONObject,
    val summary: JSONObject?,
    val file: File,
    val active: Boolean = false,
) {
    /** Stable take identity, normalized to the descriptor's upper-case UUID. */
    val id: String get() = normalizedId(descriptor.getString("id"))

    /** Camera label shown for this take. */
    val cameraLabel: String get() = descriptor.getString("cameraLabel")

    /** Take start in epoch milliseconds. */
    val startDateMillis: Long get() = descriptor.getDouble("startDate").toLong()

    /** Recorded duration in seconds; null when no summary exists. */
    val durationSeconds: Double? get() = summary.nullableDouble("duration")

    /** Measured sample rate in hertz; null when no summary exists. */
    val measuredRate: Double? get() = summary.nullableDouble("measuredRate")

    /** Estimated offset from the camera clock in seconds; null when no summary exists. */
    val approximateStartOffset: Double? get() = summary.nullableDouble("approximateStartOffset")

    /** True when the descriptor carries a verified mount calibration. */
    val isCalibrated: Boolean get() = descriptor.optJSONObject("mountCalibration") != null

    /** Operator-facing status from the descriptor, summary and live recording state. */
    val status: GyroTakeStatus get() = resolveGyroTakeStatus(descriptor, summary, active)

    /** True when the finished GCSV can be shared. */
    val canShare: Boolean get() = summary != null && !active
}

/**
 * The platform's gyro files, with the legacy on-disk layout. Take boundaries, GCSV encoding and
 * recovery validation stay in Swift; this store applies typed [GyroLogUpdate]s in order and keeps
 * the first mount move in a sidecar until the take completes or recovery finishes it.
 */
class GyroLogStore
internal constructor(
    private val root: File,
    private val native: GyroNativeApi,
    private val writeBytes: (RandomAccessFile, ByteArray) -> Unit,
) {
    /** Opens (and creates) the store under [root]. */
    constructor(root: File, native: GyroNativeApi) : this(root, native, { file, bytes ->
        file.write(bytes)
    })

    private val writers = mutableMapOf<String, RandomAccessFile>()
    private var lastFlush = 0L

    init {
        if (!root.exists() && !root.mkdirs()) throw IOException("Could not create gyro storage.")
    }

    /** Applies the ordered file updates from one logging reply. */
    fun apply(updates: List<GyroLogUpdate>) {
        for (update in updates) {
            when (update) {
                is GyroLogUpdate.Opened -> open(update.descriptor)
                is GyroLogUpdate.Appended -> {
                    val writer = writers[normalizedId(update.id)]
                        ?: throw IOException("Gyro log is not open.")
                    writeBytes(writer, update.bytes)
                }
                is GyroLogUpdate.MountMoved ->
                    writeMountMoved(normalizedId(update.id), update.offsetSeconds)
                is GyroLogUpdate.Finished -> finish(update.summary)
            }
        }
    }

    /** Synchronizes open partial files at most once per second. */
    fun flush(nowMillis: Long) {
        if (nowMillis - lastFlush < 1_000) return
        writers.values.forEach { it.fd.sync() }
        lastFlush = nowMillis
    }

    /** Releases every open file without completing the takes. */
    fun close() {
        writers.values.forEach { writer ->
            runCatching { writer.fd.sync() }
            runCatching { writer.close() }
        }
        writers.clear()
    }

    /** Releases open files and recovers every interrupted take that still can be completed. */
    fun abort() {
        close()
        recover()
    }

    /** Lists every take, newest first; a partial file hides a stale summary. */
    fun entries(): List<GyroLogEntry> =
        root.listFiles().orEmpty()
            .filter { it.isGyroDescriptor() }
            .mapNotNull { file -> runCatching { readEntry(file) }.getOrNull() }
            .sortedByDescending { it.startDateMillis }

    /** Deletes one inactive take and its metadata; a recording take is refused. */
    fun delete(entry: GyroLogEntry) {
        check(!writers.containsKey(entry.id)) { "A recording gyro log cannot be deleted." }
        if (!entry.file.delete()) throw IOException("Could not delete the gyro log.")
        File(root, "${entry.id}.summary.json").delete()
        File(root, "${entry.id}.json").delete()
        File(root, "${entry.id}.mount-moved.json").delete()
    }

    /** Returns the finished files for every id in order; any active or unfinished id is refused. */
    fun shareFiles(ids: List<String>): List<File> {
        val entries = entries().associateBy { it.id }
        return ids.map { id ->
            val entry =
                requireNotNull(entries[normalizedId(id)]) {
                    "The gyro log could not be found."
                }
            check(!entry.active) { "A recording gyro log cannot be shared." }
            check(entry.summary != null) { "An unfinished gyro log cannot be shared." }
            entry.file
        }
    }

    /** Completes every interrupted partial file, keeping the recoverable ones usable. */
    fun recover() {
        var failures = 0
        for (file in root.listFiles().orEmpty().filter { it.name.endsWith(".partial") }) {
            try {
                recoverFile(file)
            } catch (_: Exception) {
                failures += 1
            }
        }
        if (failures > 0) {
            throw IOException(
                "Some interrupted gyro logs could not be recovered. Saved logs remain available.",
            )
        }
    }

    private fun open(descriptor: JSONObject) {
        val id = normalizedId(descriptor.getString("id"))
        atomicWrite(File(root, "$id.json"), descriptor.toString())
        writers[id] = RandomAccessFile(File(root, "$id.partial"), "rw")
    }

    private fun readEntry(file: File): GyroLogEntry? {
        val descriptor = JSONObject(file.readText())
        val id = normalizedId(descriptor.getString("id"))
        require(file.name == "$id.json") { "Invalid gyro descriptor." }
        descriptor.getString("cameraLabel")
        descriptor.getDouble("startDate")
        val filename = descriptor.getString("filename")
        require(File(filename).name == filename) { "Invalid gyro filename." }
        val partial = File(root, "$id.partial")
        val artifact = if (partial.isFile) partial else File(root, filename)
        if (!artifact.isFile) return null
        val summary =
            if (partial.isFile) {
                null
            } else {
                runCatching {
                    JSONObject(File(root, "$id.summary.json").readText()).also {
                        require(normalizedId(it.getJSONObject("descriptor").getString("id")) == id)
                        it.getDouble("duration")
                        it.getDouble("measuredRate")
                        it.getDouble("largestGap")
                        it.getBoolean("isPartial")
                        it.getString("termination")
                        it.getDouble("approximateStartOffset")
                    }
                }.getOrNull()
            }
        return GyroLogEntry(descriptor, summary, artifact, active = writers.containsKey(id))
    }

    private fun recoverFile(file: File) {
        val id = normalizedId(file.name.removeSuffix(".partial"))
        val descriptor = File(root, "$id.json").readText()
        val owner = native.recoveryCreate()
        var validLength = 0L
        var summary: String? = null
        try {
            file.inputStream().use { input ->
                val buffer = ByteArray(16_384)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    validLength = native.recoveryAccept(owner, buffer.copyOf(count))
                    if (validLength < 0) {
                        throw IOException("The partial gyro log has an invalid header.")
                    }
                }
            }
        } finally {
            summary = native.recoveryFinish(owner, descriptor, mountMovedOffset(id) ?: Double.NaN)
        }
        val recovered = summary ?: throw IOException("The partial gyro log could not be recovered.")
        RandomAccessFile(file, "rw").use {
            it.setLength(validLength)
            it.fd.sync()
        }
        finish(JSONObject(recovered))
    }

    private fun finish(summary: JSONObject) {
        val descriptor = summary.getJSONObject("descriptor")
        val id = normalizedId(descriptor.getString("id"))
        val mountMoved = mountMovedOffset(id)
        if (mountMoved != null && summary.isNull("mountMovedOffset")) {
            summary.put("mountMovedOffset", mountMoved)
        }
        writers.remove(id)?.let { writer ->
            try {
                writer.fd.sync()
            } finally {
                writer.close()
            }
        }
        val filename = descriptor.getString("filename")
        require(File(filename).name == filename) { "Invalid gyro filename." }
        val partial = File(root, "$id.partial")
        val destination = File(root, filename)
        atomicWrite(File(root, "$id.summary.json"), summary.toString())
        if (!partial.renameTo(destination)) throw IOException("Could not finish the gyro log.")
        File(root, "$id.mount-moved.json").delete()
    }

    private fun writeMountMoved(id: String, offsetSeconds: Double) {
        if (!File(root, "$id.json").isFile) throw IOException("Gyro log is not open.")
        atomicWrite(
            File(root, "$id.mount-moved.json"),
            JSONObject().put("offsetSeconds", offsetSeconds).toString(),
        )
    }

    private fun mountMovedOffset(id: String): Double? {
        val file = File(root, "$id.mount-moved.json")
        if (!file.isFile) return null
        return runCatching { JSONObject(file.readText()).getDouble("offsetSeconds") }.getOrNull()
    }

    private fun atomicWrite(destination: File, value: String) {
        val temporary = File(root, "${destination.name}.tmp")
        temporary.outputStream().use { output ->
            output.write(value.toByteArray())
            output.fd.sync()
        }
        if (!temporary.renameTo(destination)) throw IOException("Could not save gyro metadata.")
    }
}

private fun File.isGyroDescriptor(): Boolean =
    name.endsWith(".json") && !name.endsWith(".summary.json") &&
        !name.endsWith(".mount-moved.json")

private fun normalizedId(value: String): String = UUID.fromString(value).toString().uppercase()

private fun JSONObject?.nullableDouble(name: String): Double? =
    if (this == null || isNull(name)) null else getDouble(name)
