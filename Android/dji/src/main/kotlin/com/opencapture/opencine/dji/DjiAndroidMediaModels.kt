package com.opencapture.opencine.dji

import java.util.Locale

data class MediaFile(
    val path: String,
    val thumbPath: String,
    val handle: Long = 0,
    val cmdHandle: Long = 0,
    val sizeBytes: Long = 0,
    val durationSeconds: Int = 0,
    val isStarred: Boolean = false,
    val resolution: String? = null,
    val fps: Int? = null,
    val proxyPath: String? = null,
    val storage: Int = 0,
    /** True when storage came from the counter of a store-specific `0x26` query. */
    val storageKnown: Boolean = false,
    val group: Int = 0,
    val handleShared: Boolean = false,
    /**
     * The handle read at the marker fixed position, before the base+step fit has vouched for it.
     * Untrusted on its own — see `MediaManifest.withCmdHandles`. Zero when the record has no marker.
     */
    val handleCandidate: Long = 0L,
) {
    val id: String get() = MediaListCommand.pageKey(this)
    val filename: String get() = path.substringAfterLast('/')
    val fileExtension: String get() = filename.substringAfterLast('.', missingDelimiterValue = "").uppercase(Locale.US)
    val kind: MediaKind get() = MediaKind.fromExtension(fileExtension)
    val isDeletable: Boolean get() = handle != 0L && !handleShared
    val favoriteHandle: Long get() = if (handle != 0L) handle else cmdHandle

    /** `YYYYMMDDHHmmss` baked into `DJI_20260814125250_0034_D.MP4`. */
    val filenameTimestamp: String?
        get() = TIMESTAMP_REGEX.find(filename)?.groupValues?.getOrNull(1)

    val dateKey: String
        get() = filenameTimestamp?.take(8).orEmpty()

    /** `DJI_…_0034_D` sequence used to fit `base + seq × step`. */
    val sequenceNumber: Int
        get() = SEQUENCE_REGEX.find(filename)?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 0

    val burstGroupKey: String?
        get() = BURST_REGEX.find(filename)?.groupValues?.getOrNull(1)

    val burstIndex: Int
        get() = BURST_REGEX.find(filename)?.groupValues?.getOrNull(2)?.toIntOrNull() ?: 0

    val isBurstLead: Boolean get() = burstGroupKey != null

    companion object {
        private val TIMESTAMP_REGEX = Regex("_(\\d{14})_")
        private val SEQUENCE_REGEX = Regex("_(\\d{4})_D")
        private val BURST_REGEX = Regex("""^(.+)_(\d{3})\.\w+$""")
    }
}

enum class MediaKind {
    VIDEO,
    PHOTO,
    ;

    companion object {
        fun fromExtension(ext: String): MediaKind =
            when (ext.uppercase(Locale.US)) {
                "JPG", "JPEG", "DNG", "HEIC", "TIF", "TIFF", "PANO" -> PHOTO
                else -> VIDEO
            }
    }
}

/** SoftAP HTTP `/v2` paths. Osmosis `PathAddressing` + `StorageRules`. */
object MediaHTTP {
    const val HOST = "192.168.2.1"
    const val PORT = 80

    fun pathUrlString(storage: Int, path: String): String = "http://$HOST/v2?storage=$storage&path=$path"

    /**
     * Guess `/v2?storage=` from the delete handle's `0x40000000` bit.
     * Internal → 1, SD → 0. Pocket 3 is the single-microSD exception (`0`).
     */
    fun storageGuess(handle: Long, singleSdStorage: Boolean): Int {
        if (singleSdStorage) return 0
        return if ((handle and MediaListCommand.INTERNAL_BIT) != 0L) 1 else 0
    }

    /**
     * `/v2?storage=` for a listed clip. Pocket 3 (single microSD) is always 0,
     * even when the manifest stamped storage 1 from the internal-handle bit or a
     * previous GET remembered 1.
     */
    fun resolvedStorage(
        stamped: Int,
        handle: Long,
        winner: Int?,
        singleSdStorage: Boolean,
    ): Int {
        if (singleSdStorage) return 0
        winner?.let { if (it == 0 || it == 1) return it }
        if (stamped == 0 || stamped == 1) return stamped
        return storageGuess(handle, singleSdStorage = false)
    }

    fun originalPath(file: MediaFile): String = file.path

    /** Clip delivery / export: the original camera file, never the LRF/XRF 720p proxy. */
    fun deliveryPath(file: MediaFile): String = originalPath(file)

    fun thumbnailPath(file: MediaFile): String = file.thumbPath

    /** Preview chain: listed proxy, derived `.LRF` (DJI) / `.XRF` (CAM_), then original. */
    fun previewPaths(file: MediaFile): List<String> {
        val seen = LinkedHashSet<String>()
        file.proxyPath?.let { seen.add(it) }
        derivedProxyPath(file)?.let { seen.add(it) }
        seen.add(file.path)
        return seen.toList()
    }

    /** LRF/XRF sidecars only. Empty for photos and clips with no DJI proxy. */
    fun proxyPaths(file: MediaFile): List<String> = previewPaths(file).filter(::isProxyPath)

    fun derivedProxyPath(file: MediaFile): String? {
        val ext = derivedProxyExtension(file.filename) ?: return null
        return "${deletingPathExtension(file.path)}.$ext"
    }

    fun derivedProxyExtension(filename: String): String? =
        when {
            filename.startsWith("CAM_") -> "XRF"
            filename.startsWith("DJI_") -> "LRF"
            else -> null
        }

    fun isProxyPath(path: String): Boolean =
        when (pathExtension(path).uppercase(Locale.US)) {
            "LRF", "LRV", "XRF" -> true
            else -> false
        }

    fun playbackMIMEType(path: String): String =
        when (pathExtension(path).uppercase(Locale.US)) {
            "JPG", "JPEG" -> "image/jpeg"
            "DNG" -> "image/x-adobe-dng"
            "HEIC" -> "image/heic"
            else -> "video/mp4"
        }

    fun playbackCacheFileName(path: String): String {
        val raw = path.replace("/", "_")
        return when (pathExtension(raw).uppercase(Locale.US)) {
            "MP4", "MOV" -> raw
            else -> "${deletingPathExtension(raw)}.mp4"
        }
    }
}

data class MediaPageSliceInfo(
    val declared: Int,
    val records: Int,
    val endMarker: Boolean,
    val ended: Boolean,
) {
    val incomplete: Boolean
        get() = declared in 1..MediaListCommand.COUNT_MAX && records < declared
}

data class MediaPageStep(
    val fresh: List<MediaFile>,
    val sdCursor: Long,
    val internalCursor: Long,
    val moreAvailable: Boolean,
)

/** `0x00/0x26` list payloads. Byte-identical to Osmosis / Mimo. */
object MediaListCommand {
    const val PAGE_SIZE = 45
    const val COUNT_MAX = 512
    const val NEWEST_SD = 0x00000001L
    const val NEWEST_INTERNAL = 0x40000001L
    const val INTERNAL_BIT = 0x40000000L
    const val SD_STORAGE = 0
    const val INTERNAL_STORAGE = 1
    const val SD_COUNTER: Int = 1
    const val INTERNAL_COUNTER: Int = 2

    val listTemplate: ByteArray =
        byteArrayOf(
            0x4A, 0x00, 0x2A, 0x10,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
            0x2D, 0x00, 0x0D, 0x01, 0x00,
            0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
            0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00,
        )

    val triggerPayload: ByteArray =
        byteArrayOf(
            0x4A, 0x04, 0x0E, 0x10,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x00, 0x00, 0x00,
        )

    fun listPayload(counter: Int, cursor: Long): ByteArray {
        val payload = listTemplate.copyOf()
        payload[4] = (counter and 0xFF).toByte()
        payload[10] = (cursor and 0xFF).toByte()
        payload[11] = ((cursor shr 8) and 0xFF).toByte()
        payload[12] = ((cursor shr 16) and 0xFF).toByte()
        payload[13] = ((cursor shr 24) and 0xFF).toByte()
        return payload
    }

    fun storeOf(file: MediaFile): Int {
        if (file.storageKnown) return file.storage
        val handle = if (file.handle != 0L) file.handle else file.cmdHandle
        if (handle != 0L) return if ((handle and INTERNAL_BIT) == 0L) SD_STORAGE else INTERNAL_STORAGE
        return if (file.group == INTERNAL_STORAGE) INTERNAL_STORAGE else SD_STORAGE
    }

    /** Store-qualified because the same camera path may exist on both stores. */
    fun pageKey(file: MediaFile): String = "${storeOf(file)}:${file.path}"

    fun storeSlice(page: List<MediaFile>, store: Int): List<MediaFile> =
        page.filter { storeOf(it) == store }

    fun oldestHandle(page: List<MediaFile>, store: Int, below: Long? = null): Long? =
        storeSlice(page, store)
            .map { it.handle }
            .filter { it != 0L && (below == null || it < below) }
            .minOrNull()

    fun seedPagination(
        page: List<MediaFile>,
        seen: MutableSet<String>,
        slices: Map<Int, MediaPageSliceInfo> = emptyMap(),
    ): MediaPageStep =
        pageStep(NEWEST_SD, NEWEST_INTERNAL, page, seen, slices, initial = true)

    fun stepPagination(
        sdCursor: Long,
        internalCursor: Long,
        page: List<MediaFile>,
        seen: MutableSet<String>,
        slices: Map<Int, MediaPageSliceInfo> = emptyMap(),
    ): MediaPageStep =
        pageStep(sdCursor, internalCursor, page, seen, slices, initial = false)

    fun hasOlderPage(recordCount: Int, cursor: Long?): Boolean {
        val c = cursor ?: return false
        if (c <= 0L) return false
        return recordCount >= PAGE_SIZE
    }

    fun storeHasOlderPage(
        sliceSize: Int,
        cursorMoved: Boolean,
        info: MediaPageSliceInfo?,
    ): Boolean =
        when {
            !cursorMoved -> false
            info == null -> sliceSize >= PAGE_SIZE
            info.incomplete -> true
            info.endMarker -> false
            else -> sliceSize >= PAGE_SIZE
        }

    private fun pageStep(
        sdCursor: Long,
        internalCursor: Long,
        page: List<MediaFile>,
        seen: MutableSet<String>,
        slices: Map<Int, MediaPageSliceInfo>,
        initial: Boolean,
    ): MediaPageStep {
        val fresh = page.filter { seen.add(pageKey(it)) }
        val sdOldest = oldestHandle(page, SD_STORAGE, if (initial) null else sdCursor)
        val internalOldest = oldestHandle(page, INTERNAL_STORAGE, if (initial) null else internalCursor)
        val more =
            fresh.isNotEmpty() &&
                (
                    storeHasOlderPage(
                        storeSlice(page, SD_STORAGE).size,
                        sdOldest != null,
                        slices[SD_STORAGE],
                    ) ||
                        storeHasOlderPage(
                            storeSlice(page, INTERNAL_STORAGE).size,
                            internalOldest != null,
                            slices[INTERNAL_STORAGE],
                        )
                )
        return MediaPageStep(
            fresh = fresh,
            sdCursor = sdOldest ?: sdCursor,
            internalCursor = internalOldest ?: internalCursor,
            moreAvailable = more,
        )
    }
}

object MediaCommands {
    const val SET_GENERAL = 0x00
    const val SET_CAMERA = 0x02
    const val CMD_MEDIA_LIST = 0x26
    const val CMD_MEDIA_CHUNK = 0x27
    const val CMD_MEDIA_DELETE = 0x28
    const val CMD_PLAYBACK = 0x0C
    const val CMD_MEDIA_FAVORITE = 0xBF

    fun enterPlaybackPayload(): ByteArray = byteArrayOf(0x01, 0x01, 0x00, 0x01)

    fun exitPlaybackPayload(): ByteArray = byteArrayOf(0x01, 0x01, 0x00, 0x00)

    /** `0x00/0x28` delete. `[count][handle:u32][counter:u32] 00 [count:u32] 01 01 00 00`. */
    fun deletePayload(handle: Long, counter: Long): ByteArray {
        val out = ByteArray(18)
        out[0] = 0x01
        writeU32LE(out, 1, handle)
        writeU32LE(out, 5, counter)
        out[9] = 0x00
        writeU32LE(out, 10, 1)
        out[14] = 0x01
        out[15] = 0x01
        out[16] = 0x00
        out[17] = 0x00
        return out
    }

    /** `0x02/0xBF` star. `01 01 [handle:u32] [counter:u32] 00 [on:u8] 00 00 00`. */
    fun favoritePayload(handle: Long, on: Boolean, counter: Long): ByteArray {
        val out = ByteArray(15)
        out[0] = 0x01
        out[1] = 0x01
        writeU32LE(out, 2, handle)
        writeU32LE(out, 6, counter)
        out[10] = 0x00
        out[11] = if (on) 0x01 else 0x00
        return out
    }

    fun isReplySuccess(payload: ByteArray): Boolean =
        payload.isNotEmpty() && payload[0] == 0.toByte()
}

internal fun pathExtension(path: String): String {
    val name = path.substringAfterLast('/')
    val dot = name.lastIndexOf('.')
    if (dot < 0) return ""
    return name.substring(dot + 1)
}

internal fun deletingPathExtension(path: String): String {
    val slash = path.lastIndexOf('/')
    val dot = path.lastIndexOf('.')
    if (dot <= slash) return path
    return path.substring(0, dot)
}

internal fun writeU32LE(dest: ByteArray, offset: Int, value: Long) {
    dest[offset] = (value and 0xFF).toByte()
    dest[offset + 1] = ((value shr 8) and 0xFF).toByte()
    dest[offset + 2] = ((value shr 16) and 0xFF).toByte()
    dest[offset + 3] = ((value shr 24) and 0xFF).toByte()
}

internal fun wrappingSub32(a: Long, b: Long): Long = (a - b) and 0xFFFF_FFFFL

internal fun wrappingAdd32(a: Long, b: Long): Long = (a + b) and 0xFFFF_FFFFL

internal fun wrappingMul32(a: Long, b: Long): Long = (a * b) and 0xFFFF_FFFFL
