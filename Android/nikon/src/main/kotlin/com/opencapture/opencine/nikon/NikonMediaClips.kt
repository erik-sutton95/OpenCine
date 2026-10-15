package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.MediaClipFormatting
import java.util.Locale

/** Shared-core browser action decoded from one `MediaListWire` record. */
public enum class NikonMediaContentKind(private val wireCode: String) {
    /** MOV/MP4/M4V proxy that opens the progressive video player. */
    PLAYABLE_PROXY("proxy"),

    /** A still image that opens the transfer-backed photo viewer. */
    STILL_PHOTO("still"),

    /** An unpaired RED master; it remains deliberately non-previewable. */
    R3D_MASTER("r3d"),

    /** A future or unrecognised media-library object. */
    UNSUPPORTED("unsupported");

    companion object {
        /** Decodes the core's stable media-action code without inspecting a filename. */
        internal fun fromWire(code: String): NikonMediaContentKind? =
            entries.firstOrNull { it.wireCode == code }
    }
}

/** Shared-core still decoder policy decoded from one `MediaListWire` record. */
public enum class NikonStillPreviewStrategy(private val wireCode: String) {
    /** JPEG and PNG may decode before the object has completely transferred. */
    PROGRESSIVE("progressive"),

    /** HEIF/TIFF decoding is attempted only after the complete cache is published. */
    COMPLETE_FILE("complete"),

    /** Nikon RAW is shown through the camera thumbnail only; no false full-preview claim. */
    THUMBNAIL_ONLY("thumbnail");

    companion object {
        /** Decodes the core's stable still-policy code without inspecting a filename. */
        internal fun fromWire(code: String): NikonStillPreviewStrategy? =
            entries.firstOrNull { it.wireCode == code }
    }
}

/** Core-authorized still policy and fallback label rendered by the Android viewer. */
public data class NikonStillPhotoClassification(
    val formatLabel: String,
    val previewStrategy: NikonStillPreviewStrategy,
)

/**
 * One browsable media object listed from the camera — the Kotlin mirror of
 * the facade's `FacadeMediaClip` / `MediaListWire` (Sources/
 * OpenZCineAndroidFacade/MediaBrowse.swift).
 */
data class NikonMediaClipRecord(
    /** PTP object handle (UInt32 as an unsigned value in a Long). */
    val handle: Long,
    /** Owning storage volume. */
    val storageId: Long,
    /** On-card size in bytes (PTP `ObjectCompressedSize`, 32-bit). */
    val sizeBytes: Long,
    /** PTP date-time string (`YYYYMMDDThhmmss`) or empty. */
    val captureDate: String,
    /** Full-image pixel size (0 when the camera omits it). */
    val pixelWidth: Int,
    val pixelHeight: Int,
    /** Sanitized on-card filename, e.g. `C0001.MOV`. */
    val filename: String,
    /** Shared-core browser action; Kotlin does not classify filename extensions. */
    val contentKind: NikonMediaContentKind,
    /** Shared-core still decoder policy; null for non-still browser actions. */
    val stillPhoto: NikonStillPhotoClassification?,
    /** Same-stem R3D master dimensions retained before the master is hidden. */
    val sourcePixelWidth: Int = 0,
    val sourcePixelHeight: Int = 0,
) {
    /** Uppercased file extension, e.g. `MOV`; empty when the name has none. */
    val codecLabel: String =
        filename.substringAfterLast('.', missingDelimiterValue = "").uppercase(Locale.US)

    /** The shared byte label (`1.28 GB`); empty for an unknown size. */
    val sizeLabel: String
        get() = MediaClipFormatting.byteLabel(sizeBytes)

    /** Grid-cell badge: size plus codec (`1.28 GB · MOV`), either part dropped when unknown. */
    val badgeLabel: String = listOf(sizeLabel, codecLabel).filter { it.isNotEmpty() }.joinToString(" · ")

}

/** Parsing and ordering for the media listing crossing the JNI seam. */
object NikonMediaClips {
    /**
     * Parses the facade's wire format — one record per line, tab-separated
     * `handle, storageID, sizeBytes, captureDate, width, height, sourceWidth,
     * sourceHeight, playable, kind, stillStrategy, stillFormatLabel, filename`
     * (filename last; it is sanitized tab/newline-free by the facade).
     * Malformed lines are skipped, never fatal: the listing is network input.
     */
    fun parse(wire: String): List<NikonMediaClipRecord> =
        wire.lineSequence()
            .mapNotNull { line ->
                val fields = line.split('\t')
                if (fields.size != 13) return@mapNotNull null
                val isPlayableProxy =
                    when (fields[8]) {
                        "1" -> true
                        "0" -> false
                        else -> return@mapNotNull null
                    }
                val contentKind = NikonMediaContentKind.fromWire(fields[9]) ?: return@mapNotNull null
                if (isPlayableProxy != (contentKind == NikonMediaContentKind.PLAYABLE_PROXY)) {
                    return@mapNotNull null
                }
                val stillPhoto =
                    when (contentKind) {
                        NikonMediaContentKind.STILL_PHOTO -> {
                            val previewStrategy =
                                NikonStillPreviewStrategy.fromWire(fields[10]) ?: return@mapNotNull null
                            val formatLabel = fields[11].ifEmpty { return@mapNotNull null }
                            NikonStillPhotoClassification(formatLabel, previewStrategy)
                        }
                        NikonMediaContentKind.PLAYABLE_PROXY,
                        NikonMediaContentKind.R3D_MASTER,
                        NikonMediaContentKind.UNSUPPORTED,
                        -> {
                            if (fields[10].isNotEmpty() || fields[11].isNotEmpty()) {
                                return@mapNotNull null
                            }
                            null
                        }
                    }
                val handle = fields[0].toLongOrNull() ?: return@mapNotNull null
                val storageId = fields[1].toLongOrNull() ?: return@mapNotNull null
                val sizeBytes = fields[2].toLongOrNull() ?: return@mapNotNull null
                val pixelWidth = fields[4].toIntOrNull() ?: return@mapNotNull null
                val pixelHeight = fields[5].toIntOrNull() ?: return@mapNotNull null
                val sourcePixelWidth = fields[6].toIntOrNull() ?: return@mapNotNull null
                val sourcePixelHeight = fields[7].toIntOrNull() ?: return@mapNotNull null
                if (
                    handle < 0 || storageId < 0 || sizeBytes < 0 || pixelWidth < 0 ||
                        pixelHeight < 0 || sourcePixelWidth < 0 || sourcePixelHeight < 0
                ) {
                    return@mapNotNull null
                }
                NikonMediaClipRecord(
                    handle = handle,
                    storageId = storageId,
                    sizeBytes = sizeBytes,
                    captureDate = fields[3],
                    pixelWidth = pixelWidth,
                    pixelHeight = pixelHeight,
                    filename = fields[12].ifEmpty { return@mapNotNull null },
                    contentKind = contentKind,
                    stillPhoto = stillPhoto,
                    sourcePixelWidth = sourcePixelWidth,
                    sourcePixelHeight = sourcePixelHeight,
                )
            }
            .toList()

    /**
     * The iOS browser's default `newest` order: capture date descending (the
     * PTP `YYYYMMDDThhmmss` format sorts lexicographically), filename
     * descending as the tiebreaker.
     */
    fun newestFirst(clips: List<NikonMediaClipRecord>): List<NikonMediaClipRecord> =
        clips.sortedWith(
            compareByDescending<NikonMediaClipRecord> { it.captureDate }
                .thenByDescending { it.filename.lowercase(Locale.US) },
        )
}
