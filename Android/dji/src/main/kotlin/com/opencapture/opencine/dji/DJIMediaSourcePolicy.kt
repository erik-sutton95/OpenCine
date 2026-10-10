package com.opencapture.opencine.dji

import com.opencapture.opencine.vocabulary.CameraModel

/** Source-specific storage facts, resolved in the integration rather than the gallery UI. */
data class DJIMediaSourcePolicy(val sourceOwnsFavorites: Boolean?, val singleSDStorage: Boolean?) {
    companion object {
        fun observed(model: CameraModel?, inPlayback: Boolean, internalTotalMb: Int): DJIMediaSourcePolicy =
            DJIMediaSourcePolicy(
                sourceOwnsFavorites = model?.let { CameraModel.looksLikeNano(it.name, it.family) },
                // Playback pushes can contain one zeroed block even when both stores are reachable.
                singleSDStorage = when {
                    model?.name?.contains("Pocket 3", ignoreCase = true) == true -> true
                    !inPlayback && internalTotalMb >= 0 -> internalTotalMb == 0
                    else -> null
                },
            )
    }
}
