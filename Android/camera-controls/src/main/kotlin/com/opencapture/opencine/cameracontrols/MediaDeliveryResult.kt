package com.opencapture.opencine.cameracontrols

import java.io.File

/** App-owned files/message facts. A prepared result does not launch an OS intent. */
sealed interface MediaDeliveryResult {
    data class Message(val text: String) : MediaDeliveryResult
    data class ShareReady(val files: List<File>) : MediaDeliveryResult
}

/** Called only by the current admitted completion on the presentation dispatcher. */
fun admittedDeliveryToast(
    outcome: MediaDeliveryResult,
    share: (List<File>) -> Boolean,
): String = when (outcome) {
    is MediaDeliveryResult.Message -> outcome.text
    is MediaDeliveryResult.ShareReady -> {
        if (!share(outcome.files)) {
            if (outcome.files.size == 1) "Couldn't share this clip." else "Couldn't share these clips."
        } else {
            "Ready to share ${outcome.files.size} clip${if (outcome.files.size == 1) "" else "s"}"
        }
    }
}

enum class MediaDeliveryDestination(
    val title: String,
    val subtitle: String,
    val actionTitle: String,
) {
    NATIVE_SHARE(
        title = "Share",
        subtitle = "Nearby Share, Files, and other apps",
        actionTitle = "Share",
    ),
}

/** Listed on the Share sheet; never selectable and never starts auth or upload. */
object MediaDeliveryUpcoming {
    val titles = listOf(
        "Google Drive",
        "Dropbox",
        "NAS (SMB)",
        "LucidLink",
        "Backblaze B2",
        "Vimeo Review",
    )
}

enum class MediaDeliveryPostExportAction {
    SYSTEM_SHARE,
    SAVE_TO_PHOTOS,
}

data class MediaDeliveryOverlayState(
    val statusLine: String,
    val batchLine: String? = null,
    val overallFraction: Double = 0.0,
    val isPreparing: Boolean = true,
    val filename: String? = null,
)

/** The original Android copy/cadence consumes the same ordered batch facts as Apple. */
fun com.opencapture.opencine.appkit.MonitorDeliveryBatchProgress.androidOverlay(
    action: com.opencapture.opencine.appkit.MonitorDeliveryPostExportAction,
): MediaDeliveryOverlayState? {
    if (!isCaching && !isSwitchingNetworks &&
        stage != com.opencapture.opencine.appkit.MonitorDeliveryBatchProgress.Stage.SAVING &&
        (isPreparingClip || action == com.opencapture.opencine.appkit.MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS)) return null
    val saving = stage == com.opencapture.opencine.appkit.MonitorDeliveryBatchProgress.Stage.SAVING
    val text = when {
        isSwitchingNetworks -> "Switching networks…"
        isCaching -> if (clipFraction > 0.0) "Caching from camera" else "Caching from camera…"
        saving -> "Saving to Photos ${if (totalClips > 0) (clipIndex - 1) * 100 / totalClips else 0}%"
        else -> "Preparing to share"
    }
    return MediaDeliveryOverlayState(text,
        batchLine = if (totalClips > 1) "Clip $clipIndex of $totalClips" else null,
        overallFraction = if (isCaching) clipFraction else overallFraction,
        isPreparing = if (isCaching) isPreparingClip else isSwitchingNetworks,
        filename = filename)
}

fun com.opencapture.opencine.appkit.MonitorDeliveryBatchOutcome<File>.androidResult(): MediaDeliveryResult = when (this) {
    is com.opencapture.opencine.appkit.MonitorDeliveryBatchOutcome.Share -> MediaDeliveryResult.ShareReady(urls)
    is com.opencapture.opencine.appkit.MonitorDeliveryBatchOutcome.SavedToPhotos -> MediaDeliveryResult.Message(
        if (count == 0) "Couldn't save clips to Photos." else "Saved $count clip${if (count == 1) "" else "s"} to Photos")
    is com.opencapture.opencine.appkit.MonitorDeliveryBatchOutcome.Failed -> MediaDeliveryResult.Message(message)
    is com.opencapture.opencine.appkit.MonitorDeliveryBatchOutcome.Uploaded -> MediaDeliveryResult.Message(summary)
}
