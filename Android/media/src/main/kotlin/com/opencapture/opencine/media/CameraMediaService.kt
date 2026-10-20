package com.opencapture.opencine.media

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.StorageVolume
import java.util.UUID

/** Opaque content identities supplied by the source. Consumers never parse them. */
@JvmInline public value class MediaAssetID(public val rawValue: String)
@JvmInline public value class MediaRepresentationID(public val rawValue: String)
public enum class MediaAssetKind { VIDEO, PHOTO }
public enum class MediaRepresentationRole { ORIGINAL, PROXY }
public data class MediaPixelSize(public val width: Int, public val height: Int)
public data class MediaRepresentation(
    public val id: MediaRepresentationID,
    public val role: MediaRepresentationRole,
    public val byteCount: Long? = null,
)

/** Source facts, distinct from local cache/favorites. Routing and raw handles remain private. */
public data class MediaAsset(
    public val id: MediaAssetID,
    public val volumeID: String? = null,
    public val filename: String,
    public val kind: MediaAssetKind? = null,
    public val capturedAt: Long? = null,
    public val durationSeconds: Double? = null,
    public val pixelSize: MediaPixelSize? = null,
    public val frameRate: Double? = null,
    public val colorLabel: String? = null,
    public val representations: List<MediaRepresentation>,
    public val deletable: Boolean? = null,
)

/** A bounded page. Null volumes are unknown, distinct from known empty storage. */
public data class MediaCatalogDelta(
    public val reset: Boolean = false,
    public val upserts: List<MediaAsset> = emptyList(),
    public val removed: List<MediaAssetID> = emptyList(),
    public val volumes: List<StorageVolume>? = null,
    public val complete: Boolean,
)

public data class MediaBrowseBinding(
    public val session: CameraSessionID,
    public val epoch: ControlEpoch,
    public val lease: UUID = UUID.randomUUID(),
)
public enum class MediaServiceFailure { UNAVAILABLE, RETIRED, UNKNOWN_ASSET, UNSUPPORTED, REFUSED }
public class MediaServiceException(public val failure: MediaServiceFailure) : IllegalStateException(failure.name)
public data class MediaTransferReceipt(public val byteCount: Long, public val expectedByteCount: Long? = null)
public enum class MediaDeleteOutcome { ACCEPTED, REFUSED, UNSUPPORTED, UNKNOWN }
public data class MediaDeleteResult(public val asset: MediaAssetID, public val outcome: MediaDeleteOutcome)

/** Owned staging writer, never a whole movie in memory. Retirement makes further writes fail. */
public interface MediaByteSink { public suspend fun write(chunk: ByteArray) }
/** Optional response length observation; an absent length remains unknown. */
public interface MediaTransferProgressSink : MediaByteSink {
    public suspend fun expectedByteCount(count: Long?)
}
public interface CameraMediaThumbnailService { public suspend fun thumbnail(asset: MediaAssetID): ByteArray }
public interface CameraMediaTransferService {
    public suspend fun transfer(representation: MediaRepresentationID, sink: MediaByteSink): MediaTransferReceipt
}
public interface CameraMediaDeleteService { public suspend fun delete(assets: List<MediaAssetID>): List<MediaDeleteResult> }
public interface MediaCatalogCursor {
    public suspend fun next(): MediaCatalogDelta?
    public fun close()
}

/** One media lifetime, borrowed across covers/rotation. Unimplemented services remain absent. */
public interface CameraMediaBrowse {
    public val binding: MediaBrowseBinding
    public val thumbnails: CameraMediaThumbnailService?
    public val transfers: CameraMediaTransferService?
    public val deletion: CameraMediaDeleteService?
    /** True while the camera holds its own media (its own gallery is open), so this browse lists nothing; null when unknown. */
    public val heldBySource: Boolean? get() = null
    public suspend fun catalog(): MediaCatalogCursor
    /** Retires before suspension; idempotent and source-owned safe return to the same session. */
    public suspend fun close()
}
public interface CameraMediaService {
    public val sessionID: CameraSessionID
    public suspend fun openBrowse(): CameraMediaBrowse
}
