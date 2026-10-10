package com.opencapture.opencine.appkit

import kotlin.math.roundToInt

public enum class MonitorDeliveryDestination {
    NATIVE_SHARE, REMOTE_UPLOAD;
    public fun title(remoteDisplayName: String?): String = if (this == NATIVE_SHARE) "Share" else remoteDisplayName ?: "Upload"
    public fun subtitle(remoteDisplayName: String?, nativeShareSubtitle: String = "Share with other apps"): String =
        if (this == NATIVE_SHARE) nativeShareSubtitle else "Upload to your ${remoteDisplayName ?: "remote"} project"
}
public enum class MonitorDeliveryPostExportAction { SYSTEM_SHARE, SAVE_TO_PHOTOS }
public data class MonitorDeliveryExportConfiguration<C, F>(
    public val logTransform: C, public val exportFormat: F,
    public val bakeLUT: Boolean = true, public val bakeLUTExposure: Boolean = true,
    public val convertLog: Boolean = false, public val includeMetadata: Boolean = true,
    public val forceReupload: Boolean = false,
)
public data class MonitorDeliveryBatchProgress(
    public val destination: MonitorDeliveryDestination, public val totalClips: Int,
    public val clipIndex: Int, public val clipFraction: Double,
    public val isCaching: Boolean = false, public val isSwitchingNetworks: Boolean = false,
    public val filename: String? = null, public val uploadCaption: String? = null, public val stage: Stage = Stage.PREPARING,
) {
    public enum class Stage { PREPARING, CACHING, EXPORTING, UPLOADING, SAVING, SWITCHING_NETWORKS, AWAITING_PHOTOS_ACCESS }
    public val overallFraction: Double get() = if (totalClips > 0)
        ((maxOf(0, clipIndex - 1).toDouble() + clipFraction) / totalClips).coerceAtMost(1.0) else 0.0
    public val isPreparingClip: Boolean get() = clipFraction <= 0.0
    public val showsBusySpinner: Boolean get() = isPreparingClip || isSwitchingNetworks || stage == Stage.SAVING || stage == Stage.AWAITING_PHOTOS_ACCESS
    public val percentText: String get() = if (isPreparingClip) "" else "${(overallFraction * 100).roundToInt()}%"
    public fun statusLine(uploadCaption: String? = null): String {
        if (isSwitchingNetworks) return "Switching networks…"
        if (stage == Stage.AWAITING_PHOTOS_ACCESS) return "Waiting for Photos access…"
        if (stage == Stage.SAVING) return "Saving to Photos…"
        val verb = if (isCaching) {
            if (isPreparingClip) "Caching from camera…" else "Caching from camera"
        } else if (destination == MonitorDeliveryDestination.NATIVE_SHARE) {
            if (clipFraction > 0 && clipFraction < 0.95) "Exporting" else if (isPreparingClip) "Preparing…" else "Preparing to share"
        } else {
            if (clipFraction > 0 && clipFraction < 0.45) "Exporting" else if (isPreparingClip) "Preparing…" else uploadCaption ?: this.uploadCaption ?: "Uploading"
        }
        return if (isPreparingClip) verb else "$verb $percentText"
    }
}
public sealed interface MonitorDeliveryBatchOutcome<A> {
    public data class Share<A>(public val urls: List<A>, public val metadataText: String?, public val stagingCleanupURL: A?) : MonitorDeliveryBatchOutcome<A>
    public data class SavedToPhotos<A>(public val count: Int) : MonitorDeliveryBatchOutcome<A>
    public data class Uploaded<A>(public val summary: String) : MonitorDeliveryBatchOutcome<A>
    public data class Failed<A>(public val message: String) : MonitorDeliveryBatchOutcome<A>
}
public class MonitorDeliveryAdmission(private val current: () -> Boolean) {
    public fun isCurrent(): Boolean = current()
}
public class MonitorDeliveryOriginalService<R>(
    public val available: (R) -> Boolean, public val acquire: suspend (R) -> Unit, public val progress: (R) -> Double?,
)
public class MonitorDeliveryExportService<R, A>(
    public val release: suspend (A) -> Unit, public val prepare: suspend (R, (Double) -> Unit) -> A?,
) {
    public constructor(prepare: suspend (R, (Double) -> Unit) -> A?) : this({}, prepare)
}
public data class MonitorDeliveryShareFiles<A>(public val urls: List<A>, public val cleanup: A? = null)
public sealed interface MonitorDeliveryPhotosService<A> {
    public class Batch<A>(public val save: suspend (List<A>) -> Int) : MonitorDeliveryPhotosService<A>
    public class PerItem<A>(public val save: suspend (A) -> Boolean) : MonitorDeliveryPhotosService<A>
}
/** Existing OS authorization, admitted before cache or export work. */
public class MonitorDeliveryPhotosAuthorizationService(
    public val isPending: () -> Boolean, public val authorize: suspend () -> Unit,
)
public class MonitorDeliveryUploadService<A>(public val progressCaption: String = "Uploading", public val upload: suspend (A, (Double) -> Unit) -> Unit)
public class MonitorDeliveryInternetService<H>(
    public val needsHop: () -> Boolean, public val begin: () -> H, public val owns: (H) -> Boolean,
    public val wait: suspend (H) -> Boolean, public val restoreEntered: suspend (H) -> Unit,
    public val restore: (H) -> Unit,
) {
    public constructor(needsHop: () -> Boolean, begin: () -> H, owns: (H) -> Boolean,
        wait: suspend (H) -> Boolean, restore: (H) -> Unit) :
        this(needsHop, begin, owns, wait, { restore(it) }, restore)
}
public enum class MonitorDeliveryItemFailurePolicy { STOP, CONTINUE_ITEMS }
/** Immutable exercised transaction and empty-summary behavior, independent of source brand. */
public data class MonitorDeliveryBatchBehavior(
    public val nativeFailures: MonitorDeliveryItemFailurePolicy = MonitorDeliveryItemFailurePolicy.STOP,
    public val photosFailures: MonitorDeliveryItemFailurePolicy = MonitorDeliveryItemFailurePolicy.STOP,
    public val emptyUploadSucceeds: Boolean = false,
    public val singleUploadFailureUsesDetail: Boolean = true,
)
public data class MonitorDeliveryBatchCounts(
    public val prepared: Int, public val uploaded: Int, public val skipped: Int,
    public val failed: Int, public val uncached: Int,
)
public class MonitorDeliveryBatchPolicy(
    public val cacheFailure: (Int) -> String = { "Couldn't cache $it clip(s) from the camera. Check the connection and try again." },
    public val emptySelection: String = "Select at least one clip.", public val noPrepared: String? = null,
    public val internetFailure: String = "Couldn't reach the internet after leaving the camera's Wi-Fi. Check cellular or home Wi-Fi and try again.",
    public val behavior: MonitorDeliveryBatchBehavior = MonitorDeliveryBatchBehavior(),
    public val nativeSummary: (MonitorDeliveryBatchCounts) -> String? = { null },
    public val photosFailure: (Int, Int) -> String? = { _, _ -> null },
)

public fun <A> MonitorDeliveryBatchOutcome<A>.completion(): MonitorDeliveryCompletion<MonitorDeliveryBatchOutcome<A>, MonitorDeliveryShareFiles<A>> = when (this) {
    is MonitorDeliveryBatchOutcome.Share -> MonitorDeliveryCompletion(this, share = MonitorDeliveryShareFiles(urls, stagingCleanupURL))
    is MonitorDeliveryBatchOutcome.SavedToPhotos -> MonitorDeliveryCompletion(this, toast = "Saved $count clip${if (count == 1) "" else "s"} to Photos")
    is MonitorDeliveryBatchOutcome.Uploaded -> MonitorDeliveryCompletion(this, toast = summary)
    is MonitorDeliveryBatchOutcome.Failed -> MonitorDeliveryCompletion(this, toast = message)
}
