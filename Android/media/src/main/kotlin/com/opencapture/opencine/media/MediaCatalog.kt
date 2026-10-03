package com.opencapture.opencine.media

import com.opencapture.opencine.core.StorageVolume

/** Source identities alone merge/remove assets. Filenames and locations are never identities. */
public data class MediaCatalog(
    public val assets: List<MediaAsset> = emptyList(),
    public val volumes: List<StorageVolume>? = null,
    public val complete: Boolean = false,
) {
    public fun applying(delta: MediaCatalogDelta): MediaCatalog {
        val removed = delta.removed.toSet()
        val values = linkedMapOf<MediaAssetID, MediaAsset>()
        if (!delta.reset) assets.filterNot { it.id in removed }.forEach { values[it.id] = it }
        delta.upserts.forEach { values[it.id] = it }
        return MediaCatalog(values.values.toList(), delta.volumes ?: volumes, delta.complete)
    }
}
