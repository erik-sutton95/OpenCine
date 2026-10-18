package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.ByteCountLabel
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
     * Untrusted on its own (see `MediaManifest.withCmdHandles` in dji). Zero when the record has no marker.
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
            // Split as `_YYYYMMDD_HHMMSS_` (`VID_20260916_123456_00_001.mp4`).
            ?: DATE_TIME_REGEX.find(filename)?.groupValues?.let { it[1] + it[2] }

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
        private val DATE_TIME_REGEX = Regex("_(\\d{8})_(\\d{6})_")
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

/** iOS `MediaCacheGrade`. Playback grades the proxy; Share needs the original. */
enum class MediaCacheGrade {
    NONE,
    PROXY,
    ORIGINAL,
    ;

    val isPlayableOffline: Boolean get() = this != NONE
    val isProxyOnly: Boolean get() = this == PROXY

    companion object {
        fun resolve(hasOriginal: Boolean, hasProxy: Boolean): MediaCacheGrade =
            when {
                hasOriginal -> ORIGINAL
                hasProxy -> PROXY
                else -> NONE
            }
    }
}

/**
 * Where one camera serves its files: `/v2?storage=&path=` on [MediaHTTP.HOST], or each file at its own
 * path ([directPath]). Per session (the label profile's route), never process-wide.
 */
data class MediaRoute(val host: String = MediaHTTP.HOST, val directPath: Boolean = false) {
    fun pathUrlString(storage: Int, path: String): String =
        if (directPath) "http://$host${if (path.startsWith("/")) path else "/$path"}"
        else "http://$host/v2?storage=$storage&path=$path"

    companion object {
        /** The camera SoftAP `/v2` route. */
        val CAMERA_SOFT_AP = MediaRoute()
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

/** Store qualification for listed files (the dji list payloads and paging build on it). */
object MediaListCommand {
    const val INTERNAL_BIT = 0x40000000L
    const val SD_STORAGE = 0
    const val INTERNAL_STORAGE = 1

    /** Store selected by the query that returned [file], else the handle bit, else the group. */
    fun storeOf(file: MediaFile): Int {
        if (file.storageKnown) return file.storage
        val handle = if (file.handle != 0L) file.handle else file.cmdHandle
        if (handle != 0L) return if ((handle and INTERNAL_BIT) == 0L) SD_STORAGE else INTERNAL_STORAGE
        return if (file.group == INTERNAL_STORAGE) INTERNAL_STORAGE else SD_STORAGE
    }

    /** Store-qualified because the same camera path may exist on both stores. */
    fun pageKey(file: MediaFile): String = "${storeOf(file)}:${file.path}"
}

enum class MediaLibraryTab {
    ALL,
    VIDEOS,
    PHOTOS,
    FAVORITES,
}

enum class MediaLibrarySort {
    NEWEST,
    OLDEST,
    NAME,
    RATING,
    ;

    val next: MediaLibrarySort
        get() =
            when (this) {
                NEWEST -> OLDEST
                OLDEST -> NAME
                NAME -> RATING
                RATING -> NEWEST
            }

    val menuLabel: String
        get() =
            when (this) {
                NEWEST -> "Newest"
                OLDEST -> "Oldest"
                NAME -> "Name"
                RATING -> "Rating"
            }
}

object MediaLibraryQuery {
    fun filtered(
        files: List<MediaFile>,
        tab: MediaLibraryTab,
        formats: Set<String> = emptySet(),
        resolutions: Set<String> = emptySet(),
        dateStart: String? = null,
        dateEnd: String? = null,
        colors: Set<Int> = emptySet(),
        shotColors: Map<String, Int> = emptyMap(),
        storage: Int? = null,
        localFavorites: Set<String> = emptySet(),
    ): List<MediaFile> =
        files.filter { file ->
            when (tab) {
                MediaLibraryTab.ALL -> true
                MediaLibraryTab.VIDEOS -> file.kind == MediaKind.VIDEO
                MediaLibraryTab.PHOTOS -> file.kind == MediaKind.PHOTO
                MediaLibraryTab.FAVORITES -> file.isStarred || localFavorites.contains(file.path)
            } &&
                (formats.isEmpty() || formats.contains(file.fileExtension)) &&
                (resolutions.isEmpty() || resolutions.contains(file.resolution.orEmpty())) &&
                dateMatches(file.dateKey, dateStart, dateEnd) &&
                (colors.isEmpty() || shotColors[file.path]?.let(colors::contains) == true) &&
                (storage == null || file.storage == storage)
        }

    private fun dateMatches(key: String, start: String?, end: String?): Boolean {
        if (start == null && end == null) return true
        if (key.isEmpty()) return false
        if (start != null && key < start) return false
        if (end != null && key > end) return false
        return true
    }

    /** Filename `YYYYMMDD` as UTC calendar year-month-day. Not an instant. */
    fun dateKeyFromMillis(millis: Long): String {
        val date = java.time.Instant.ofEpochMilli(millis).atZone(java.time.ZoneOffset.UTC).toLocalDate()
        return String.format(Locale.US, "%04d%02d%02d", date.year, date.monthValue, date.dayOfMonth)
    }

    fun millisFromDateKey(key: String): Long? {
        if (key.length != 8) return null
        val year = key.substring(0, 4).toIntOrNull() ?: return null
        val month = key.substring(4, 6).toIntOrNull() ?: return null
        val day = key.substring(6, 8).toIntOrNull() ?: return null
        return runCatching {
            java.time.LocalDate.of(year, month, day)
                .atStartOfDay(java.time.ZoneOffset.UTC)
                .toInstant()
                .toEpochMilli()
        }.getOrNull()
    }

    /** Offline library: keep only files the phone can play without the camera. */
    fun cachedOnly(files: List<MediaFile>, cachedPaths: Set<String>): List<MediaFile> =
        files.filter { cachedPaths.contains(it.path) }

    fun sorted(files: List<MediaFile>, by: MediaLibrarySort): List<MediaFile> =
        when (by) {
            MediaLibrarySort.NEWEST ->
                files.sortedByDescending { it.filenameTimestamp.orEmpty() }
            MediaLibrarySort.OLDEST ->
                files.sortedBy { it.filenameTimestamp.orEmpty() }
            MediaLibrarySort.NAME ->
                files.sortedWith { a, b -> a.filename.compareTo(b.filename, ignoreCase = true) }
            MediaLibrarySort.RATING ->
                files.sortedWith { lhs, rhs ->
                    if (lhs.isStarred != rhs.isStarred) {
                        if (lhs.isStarred) -1 else 1
                    } else {
                        rhs.filenameTimestamp.orEmpty().compareTo(lhs.filenameTimestamp.orEmpty())
                    }
                }
        }
}

object MediaClipFormatting {
    fun durationLabel(seconds: Int): String {
        if (seconds <= 0) return "0:00"
        val h = seconds / 3600
        val m = (seconds % 3600) / 60
        val s = seconds % 60
        return if (h > 0) {
            String.format(Locale.US, "%d:%02d:%02d", h, m, s)
        } else {
            String.format(Locale.US, "%d:%02d", m, s)
        }
    }

    fun durationLabel(seconds: Double): String {
        if (!seconds.isFinite() || seconds < 0) return "0:00"
        return durationLabel(seconds.toInt())
    }

    /** Decimal byte labels; zero in a file manifest means an unknown size. */
    fun byteLabel(bytes: Long): String = if (bytes <= 0) "" else ByteCountLabel.label(bytes)
}

fun pathExtension(path: String): String {
    val name = path.substringAfterLast('/')
    val dot = name.lastIndexOf('.')
    if (dot < 0) return ""
    return name.substring(dot + 1)
}

fun deletingPathExtension(path: String): String {
    val slash = path.lastIndexOf('/')
    val dot = path.lastIndexOf('.')
    if (dot <= slash) return path
    return path.substring(0, dot)
}
