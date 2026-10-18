package com.opencapture.opencine.nikon

import java.util.Locale

/**
 * Everything one camera-card deletion removes, and why. The confirmation copy and the delete run
 * from the same expansion so they can never disagree (iOS `DeletionPlan`). The RAW+JPEG pair rule
 * is the one the gallery projection's `rawCompanion` uses.
 */
public data class NikonMediaDeletionPlan(
    val targets: List<NikonMediaClipRecord>,
    /** RAW siblings pulled in behind requested JPEGs. */
    val pairCount: Int,
    /** Same-stem camera masters pulled in behind requested proxies. */
    val masterCount: Int,
    /** Cross-card copies of the same shots (backup recording, split RAW) pulled in. */
    val backupCount: Int,
) {
    public companion object {
        /**
         * Expands a request to each shot's RAW sibling, its hidden camera master and the cross-card
         * twins of all of those, de-duplicated in selection order. [owner] names each clip's cache
         * bucket so two cameras' formulaic `DSC_0001` stems never pair in the offline library.
         */
        public fun of(
            catalog: List<NikonMediaClipRecord>,
            selection: List<NikonMediaClipRecord>,
            owner: (NikonMediaClipRecord) -> String,
        ): NikonMediaDeletionPlan {
            val targets = LinkedHashMap<NikonMediaObjectIdentity, NikonMediaClipRecord>()
            var pairs = 0
            var masters = 0
            var backups = 0
            fun insert(clip: NikonMediaClipRecord): Boolean = targets.putIfAbsent(NikonMediaObjectIdentity(clip), clip) == null
            selection.forEach { clip ->
                val shot = buildList {
                    add(clip)
                    rawSibling(catalog, clip, owner)?.let(::add)
                    addAll(linkedMasters(catalog, clip, owner))
                }
                shot.forEachIndexed { index, piece ->
                    if (insert(piece) && index > 0) {
                        if (isRaw(piece)) pairs += 1 else masters += 1
                    }
                    crossCardTwins(catalog, piece, owner).forEach { twin -> if (insert(twin)) backups += 1 }
                }
            }
            return NikonMediaDeletionPlan(targets.values.toList(), pairs, masters, backups)
        }

        /** The same-shot RAW behind a JPEG (bucket, storage slot, case-insensitive stem); null otherwise. */
        public fun rawSibling(
            catalog: List<NikonMediaClipRecord>,
            clip: NikonMediaClipRecord,
            owner: (NikonMediaClipRecord) -> String,
        ): NikonMediaClipRecord? = rawPartner(catalog, clip, { it }, owner)

        /**
         * Split recording writes RAW and JPEG to different cards and those stay separate items, so
         * the storage slot is part of the key.
         */
        internal fun <T> rawPartner(items: List<T>, item: T, clip: (T) -> NikonMediaClipRecord, owner: (T) -> String): T? {
            if (!isJpeg(clip(item))) return null
            val key = pairKey(owner(item), clip(item))
            return items.firstOrNull { isRaw(clip(it)) && pairKey(owner(it), clip(it)) == key }
        }

        internal fun pairKey(owner: String, clip: NikonMediaClipRecord): String = "$owner/${clip.storageId}/${stem(clip)}"

        private fun isJpeg(clip: NikonMediaClipRecord) = NikonAndroidGalleryProjectionPolicy.formatKey(clip) == "JPEG"

        private fun isRaw(clip: NikonMediaClipRecord) = NikonAndroidGalleryProjectionPolicy.formatKey(clip) == "NEF"

        private fun stem(clip: NikonMediaClipRecord) = clip.filename.substringBeforeLast('.').lowercase(Locale.US)

        /**
         * Backup recording writes the shot to both cards and series membership is same-storage, so a
         * delete widens to same-bucket, same-stem, same-second copies on ANOTHER card. An undated
         * clip never matches (every undated file would twin).
         */
        private fun crossCardTwins(
            catalog: List<NikonMediaClipRecord>,
            clip: NikonMediaClipRecord,
            owner: (NikonMediaClipRecord) -> String,
        ): List<NikonMediaClipRecord> {
            if (clip.captureDate.isEmpty()) return emptyList()
            val bucket = owner(clip)
            return catalog.filter {
                it.storageId != clip.storageId && owner(it) == bucket &&
                    it.captureDate == clip.captureDate && stem(it) == stem(clip)
            }
        }

        /** Same-stem camera masters (`.R3D`, `.NEV`) the grid hides behind a playable proxy on its card. */
        private fun linkedMasters(
            catalog: List<NikonMediaClipRecord>,
            clip: NikonMediaClipRecord,
            owner: (NikonMediaClipRecord) -> String,
        ): List<NikonMediaClipRecord> {
            if (clip.contentKind != NikonMediaContentKind.PLAYABLE_PROXY) return emptyList()
            val bucket = owner(clip)
            return catalog.filter {
                NikonMediaObjectIdentity(it) != NikonMediaObjectIdentity(clip) &&
                    it.storageId == clip.storageId && owner(it) == bucket &&
                    it.filename.substringAfterLast('.', "").lowercase(Locale.US) in masterExtensions &&
                    stem(it) == stem(clip)
            }
        }

        private val masterExtensions = setOf("r3d", "nev")
    }
}
