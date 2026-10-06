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
