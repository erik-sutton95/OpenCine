package com.opencapture.opencine.frameio

import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Non-secret clip facts the app hands over for the sidecar of one confirmed upload. */
data class FrameioSidecarFacts(
    val cameraID: String,
    val captureDate: String,
    val originalFilename: String,
    val lutName: String?,
)

/** Writes a local sidecar only after Frame.io confirms the upload. */
interface FrameioMetadataSidecarWriter {
    suspend fun recordSuccessfulDelivery(
        facts: FrameioSidecarFacts,
        deliveryFilename: String,
        byteCount: Long,
        destination: FrameioDestination,
    )
}

object NoFrameioMetadataSidecarWriter : FrameioMetadataSidecarWriter {
    override suspend fun recordSuccessfulDelivery(
        facts: FrameioSidecarFacts,
        deliveryFilename: String,
        byteCount: Long,
        destination: FrameioDestination,
    ) = Unit
}

/** Stable, secret-free sidecar payload written only after a confirmed upload. */
data class FrameioMetadataSidecar(
    val cameraID: String,
    val captureDate: String,
    val deliveredAt: String,
    val deliveryFilename: String,
    val lutName: String?,
    val originalFilename: String,
    val projectName: String,
    val sizeBytes: Long,
)

/** Small JSON encoder kept Android-free so escaping and field policy are host-testable. */
object FrameioMetadataSidecarCodec {
    fun encode(value: FrameioMetadataSidecar): String =
        buildString {
            append("{\n")
            appendField("cameraID", value.cameraID)
            appendField("captureDate", value.captureDate)
            appendField("deliveredAt", value.deliveredAt)
            appendField("deliveryFilename", value.deliveryFilename)
            appendNullableField("lutName", value.lutName)
            appendField("originalFilename", value.originalFilename)
            appendField("projectName", value.projectName)
            append("  \"sizeBytes\": ${value.sizeBytes},\n")
            append("  \"version\": 1\n")
            append('}')
        }

    private fun StringBuilder.appendField(name: String, value: String) {
        append("  ")
        append(jsonString(name))
        append(": ")
        append(jsonString(value))
        append(",\n")
    }

    private fun StringBuilder.appendNullableField(name: String, value: String?) {
        append("  ")
        append(jsonString(name))
        append(": ")
        append(value?.let(::jsonString) ?: "null")
        append(",\n")
    }

    private fun jsonString(value: String): String =
        buildString {
            append('"')
            value.forEach { character ->
                when (character) {
                    '"' -> append("\\\"")
                    '\\' -> append("\\\\")
                    '\b' -> append("\\b")
                    '\u000C' -> append("\\f")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else ->
                        if (character.code < 0x20) {
                            append("\\u")
                            append(character.code.toString(16).padStart(4, '0'))
                        } else {
                            append(character)
                        }
                }
            }
            append('"')
        }
}

/** App-private, bounded metadata history. OAuth values and upload URLs never enter a sidecar. */
class AndroidFrameioMetadataSidecarWriter(
    private val root: Path,
    private val fallbackStem: String,
    private val clock: () -> Long = System::currentTimeMillis,
) : FrameioMetadataSidecarWriter {
    override suspend fun recordSuccessfulDelivery(
        facts: FrameioSidecarFacts,
        deliveryFilename: String,
        byteCount: Long,
        destination: FrameioDestination,
    ) {
        withContext(Dispatchers.IO) {
            Files.createDirectories(root)
            val deliveredAt = clock()
            val body =
                FrameioMetadataSidecarCodec.encode(
                    FrameioMetadataSidecar(
                        cameraID = facts.cameraID,
                        captureDate = facts.captureDate,
                        deliveredAt = Instant.ofEpochMilli(deliveredAt).toString(),
                        deliveryFilename = deliveryFilename,
                        lutName = facts.lutName,
                        originalFilename = facts.originalFilename,
                        projectName = destination.projectName,
                        sizeBytes = byteCount,
                    ),
                )
            val stem = safeSidecarStem(facts.originalFilename)
            val target = root.resolve("$stem-$deliveredAt-${UUID.randomUUID()}.meta.json")
            val temporary = root.resolve(".${target.fileName}.tmp")
            try {
                Files.write(temporary, body.toByteArray(Charsets.UTF_8))
                Files.move(
                    temporary,
                    target,
                    StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING,
                )
                pruneSidecars()
            } finally {
                Files.deleteIfExists(temporary)
            }
        }
    }

    private fun pruneSidecars() {
        val entries =
            Files.list(root).use { paths ->
                paths.iterator().asSequence()
                    .filter { path -> path.fileName.toString().endsWith(".meta.json") }
                    .sortedBy { path -> Files.getLastModifiedTime(path).toMillis() }
                    .toList()
            }
        entries.take((entries.size - MAXIMUM_SIDECARS).coerceAtLeast(0)).forEach { path ->
            runCatching { Files.deleteIfExists(path) }
        }
    }

    private fun safeSidecarStem(filename: String): String =
        filename.substringBeforeLast('.', missingDelimiterValue = filename)
            .map { character ->
                if (character.isLetterOrDigit() || character == '-' || character == '_') {
                    character
                } else {
                    '_'
                }
            }
            .joinToString("")
            .take(64)
            .ifBlank { fallbackStem }

    private companion object {
        const val MAXIMUM_SIDECARS = 100
    }
}
