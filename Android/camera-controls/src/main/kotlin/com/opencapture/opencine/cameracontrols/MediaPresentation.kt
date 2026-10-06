package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.MediaClipFormatting
import com.opencapture.opencine.vocabulary.MediaFile
import com.opencapture.opencine.vocabulary.MediaKind
import com.opencapture.opencine.vocabulary.MediaLibraryTab

enum class MediaBrowserLayout {
    GRID,
    LIST,
}

enum class MediaThumbnailSize {
    SMALL,
    MEDIUM,
    LARGE,
    ;

    val gridMinimumDp: Int
        get() =
            when (this) {
                SMALL -> 148
                MEDIUM -> 210
                LARGE -> 280
            }

    val gridMaximumDp: Int
        get() =
            when (this) {
                SMALL -> 200
                MEDIUM -> 300
                LARGE -> 380
            }

    val gridIconSizeDp: Int
        get() =
            when (this) {
                SMALL -> 9
                MEDIUM -> 12
                LARGE -> 15
            }

    val accessibilityLabel: String
        get() =
            when (this) {
                SMALL -> "Small thumbnails"
                MEDIUM -> "Medium thumbnails"
                LARGE -> "Large thumbnails"
            }
}

object MediaClipPresentation {
    fun resolutionLabel(resolution: String?): String? {
        if (resolution.isNullOrEmpty()) return null
        val width = resolution.substringBefore('x').toIntOrNull()
        return when {
            width == null -> resolution
            width >= 3840 -> "4K"
            width >= 2560 -> "2.7K"
            width >= 1920 -> "1080p"
            width >= 1280 -> "720p"
            else -> resolution
        }
    }

    fun dateLabel(dateKey: String): String {
        if (dateKey.length != 8) return dateKey
        return "${dateKey.substring(0, 4)}-${dateKey.substring(4, 6)}-${dateKey.substring(6, 8)}"
    }

    fun metadataLine(file: MediaFile, durationOverride: String? = null): String {
        val parts = ArrayList<String>(3)
        resolutionLabel(file.resolution)?.let { parts.add(it) }
        val bytes = MediaClipFormatting.byteLabel(file.sizeBytes)
        if (bytes.isNotEmpty()) parts.add(bytes)
        if (file.kind == MediaKind.VIDEO) {
            parts.add(durationOverride ?: MediaClipFormatting.durationLabel(file.durationSeconds))
        }
        return parts.joinToString(" · ")
    }
}

/** Operator-facing media-browser copy. Never name a sister app. */
object MediaLibraryCopy {
    const val FILTER_EMPTY = "Nothing in this tab matches the filters."
    const val EMPTY_ALL = "Nothing on this camera yet. Record a clip, then pull to refresh."
    const val EMPTY_FAVORITES = "Nothing favorited yet. Star a clip to find it here."
    const val EMPTY_VIDEOS = "No videos on this camera yet. Record a clip, then pull to refresh."
    const val EMPTY_PHOTOS = "No photos on this camera yet. Capture a still, then pull to refresh."
    const val DISCONNECTED = "Connect the camera to list clips on the body."
    const val DISCONNECTED_EMPTY_CACHE =
        "Nothing cached on this phone. Connect the camera to list clips on the body."
    const val PROXY_TAG = "Proxy"
    const val PROXY_HELP = "720p preview. Connect the camera to share the original."

    fun headerTitle(category: MediaLibraryTab): String =
        when (category) {
            MediaLibraryTab.ALL -> "All clips"
            MediaLibraryTab.VIDEOS -> "Videos"
            MediaLibraryTab.PHOTOS -> "Photos"
            MediaLibraryTab.FAVORITES -> "Favorites"
        }

    /** The empty gallery's line: offline (with or without listed clips), filtered, or the tab's own. */
    fun emptySubtitle(isLive: Boolean, hasListedClips: Boolean, activeFilterCount: Int, category: MediaLibraryTab): String =
        when {
            !isLive ->
                if (!hasListedClips) DISCONNECTED
                else DISCONNECTED_EMPTY_CACHE
            activeFilterCount > 0 -> FILTER_EMPTY
            category == MediaLibraryTab.FAVORITES -> EMPTY_FAVORITES
            category == MediaLibraryTab.VIDEOS -> EMPTY_VIDEOS
            category == MediaLibraryTab.PHOTOS -> EMPTY_PHOTOS
            else -> EMPTY_ALL
        }
}

object MediaOperatorCopy {
    const val LISTING = "Listing camera clips…"
    const val NOT_CONNECTED = "Connect the camera to list clips."
    const val PLAYBACK_FAILED = "Camera did not enter playback."
    const val BROWSING_ON_CAMERA = "Playback is open on the camera. Close to return to live view."
    const val NO_CLIPS = "No clips on the camera."
    const val LIST_FAILED = "Could not list camera clips."
    const val NOT_DELETABLE = "That clip cannot be deleted from here."
    const val DELETE_FAILED = "Could not delete that clip."
    const val DOWNLOAD_FAILED = "Could not download that clip."
    const val THUMB_FAILED = "Could not load that thumbnail."
    const val CLIP_OPEN_FAILED = "Could not open that clip."
    const val CLIP_LOADING = "Loading clip from camera…"
    const val CLIP_NOT_CACHED = "This clip is not cached on the phone."
}
