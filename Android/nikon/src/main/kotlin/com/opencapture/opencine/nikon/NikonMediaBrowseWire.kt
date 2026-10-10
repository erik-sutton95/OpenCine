package com.opencapture.opencine.nikon


/** Stable persisted identity shared by page additions and R3D-pair removals. */
public data class NikonMediaObjectIdentity(
    val storageID: Long,
    val handle: Long,
    val captureDate: String,
    val filename: String,
) {
    constructor(clip: NikonMediaClipRecord) :
        this(clip.storageId, clip.handle, clip.captureDate, clip.filename)
}

/** One decoded page from the shared Swift media-browse cursor. */
public data class NikonMediaBrowsePage(
    val clips: List<NikonMediaClipRecord>,
    val removedObjects: List<NikonMediaObjectIdentity>,
    val inspectedObjectCount: Int,
    val hasMore: Boolean,
)

/** Incremental catalog state delivered to the Compose media browser. */
public data class NikonMediaBrowseSnapshot(
    /** Full newest-first catalog for the incremental Compose presentation. */
    val clips: List<NikonMediaClipRecord>,
    /** Additions from this native page only, for bounded persistence work. */
    val addedClips: List<NikonMediaClipRecord>,
    val removedObjects: List<NikonMediaObjectIdentity>,
    val hasMore: Boolean,
)

/** One native cursor and the card generation captured before media ownership. */
public data class NikonMediaBrowseStart(
    val cursor: Long,
    val storageSlots: List<CameraStorageSlotStatus>,
)

/** Stable parser for `MediaBrowseStartWire` from the Swift facade. */
public object NikonMediaBrowseStarts {
    private const val VERSION = "OZCMEDIASTART1"

    fun parse(wire: String?): NikonMediaBrowseStart? {
        val separator = wire?.indexOf('\n')?.takeIf { it > 0 } ?: return null
        val header = wire.substring(0, separator).split('\t')
        if (header.size != 2 || header[0] != VERSION) return null
        val cursor = header[1].toLongOrNull()?.takeIf { it > 0 } ?: return null
        val readback = CameraPropertySnapshotWire.decode(wire.substring(separator + 1))
        if (!readback.isValid || readback.result != NativePropertyRefreshResult.MEDIA_BUSY) {
            return null
        }
        return NikonMediaBrowseStart(cursor, readback.snapshot.storageSlots)
    }
}

/** Stable parser for `MediaBrowsePageWire` from the Swift facade. */
public object NikonMediaBrowsePages {
    private const val VERSION = "OZCMEDIA2"
    private const val MAXIMUM_PAGE_SIZE = 128

    fun parse(wire: String): NikonMediaBrowsePage? {
        val lines = wire.split('\n')
        val header = lines.firstOrNull()?.split('\t') ?: return null
        if (header.size != 4 || header[0] != VERSION) return null
        val hasMore =
            when (header[1]) {
                "0" -> false
                "1" -> true
                else -> return null
            }
        val inspectedObjectCount =
            header[2].toIntOrNull()?.takeIf { it in 0..MAXIMUM_PAGE_SIZE } ?: return null
        val removalCount =
            header[3].toIntOrNull()?.takeIf { it in 0..MAXIMUM_PAGE_SIZE } ?: return null
        if (lines.size < 1 + removalCount) return null
        val removedObjects =
            lines.drop(1).take(removalCount).map { line ->
                val fields = line.split('\t')
                if (fields.size != 5 || fields[0] != "-") return null
                NikonMediaObjectIdentity(
                    storageID = fields[1].unsignedObjectValueOrNull() ?: return null,
                    handle = fields[2].unsignedObjectValueOrNull() ?: return null,
                    captureDate = fields[3],
                    filename = fields[4].ifEmpty { return null },
                )
            }
        val records = lines.drop(1 + removalCount).joinToString(separator = "\n")
        val clips = NikonMediaClips.parse(records)
        if (clips.size + removedObjects.size > MAXIMUM_PAGE_SIZE) return null
        return NikonMediaBrowsePage(
            clips = clips,
            removedObjects = removedObjects,
            inspectedObjectCount = inspectedObjectCount,
            hasMore = hasMore,
        )
    }
}

/** Small injectable boundary around the three blocking JNI cursor calls. */
public interface NikonMediaBrowseGateway {
    fun begin(): String?

    fun next(cursor: Long, maxObjects: Int): String?

    fun cancel(cursor: Long)

    fun exit() = Unit
}

private fun String.unsignedObjectValueOrNull(): Long? =
    toLongOrNull()?.takeIf { it in 0..0xFFFF_FFFFL }
