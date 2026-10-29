package com.opencapture.opencine.appkit

import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import kotlin.time.Duration

/**
 * What a media source contributes to a delivery run. Everything else (ordering, progress,
 * Photos, upload history, the run lifetime) is the coordinator's.
 */
public class MonitorDeliverySource<R, C, F>(
    public val originals: MonitorDeliveryOriginalService<R>,
    /**
     * The file delivered for one record under the accepted configuration: the cached original,
     * or an export of it. Null skips the record (not eligible).
     */
    public val prepare: suspend (R, MonitorDeliveryExportConfiguration<C, F>?, (Double) -> Unit) -> File?,
    /** Releases a file [prepare] made for this run; a returned original is never removed. */
    public val release: suspend (File) -> Unit = {},
    public val filename: (R) -> String,
    /** The "Include metadata" summary of the delivered records. */
    public val metadata: (List<R>) -> String? = { null },
    /** The outcome when no record could be prepared, or null for the shared default. */
    public val noPrepared: (List<R>) -> String? = { null },
    /** Reads the source's cache facts (off the main thread) before the run asks [originals]. */
    public val load: suspend () -> Unit = {},
)

/** A remote upload's services, bound to one accepted run (its captured project included). */
public class MonitorDeliveryRemoteRun<R>(
    public val progressCaption: String,
    public val upload: suspend (R, File, (Double) -> Unit) -> Unit,
    public val history: MonitorDeliveryUploadHistory<R>? = null,
    public val reupload: Boolean = false,
    /** The account or destination the run was accepted for is still the remote's current one. */
    public val admission: MonitorDeliveryAdmission = MonitorDeliveryAdmission { true },
    /**
     * What the route left to report once the run ended (a camera rejoin that could not be
     * verified), added to the run's outcome so the toast never hides it.
     */
    public val routeNote: () -> String? = { null },
)

/**
 * The app-scoped delivery owner every app composes (A4-10): one run lifetime over the shared
 * batch progress and the share files the root chrome presents. A run survives leaving the
 * gallery or the player; only the app root closes it.
 */
public class MonitorDeliveryCoordinator(
    scope: CoroutineScope,
    sleep: suspend (Duration) -> Unit = { delay(it) },
    releaseShare: (MonitorDeliveryShareFiles<File>) -> Unit = {},
) {
    public val lifetime: MonitorDeliveryModel<MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<File>, MonitorDeliveryShareFiles<File>> =
        MonitorDeliveryModel(scope, sleep, releaseShare)

    /** The run that holds the camera or the route; a successor joins it before starting. */
    public var capturedRun: MonitorDeliveryRunHandle? = null
        private set

    public val isActive: Boolean get() = lifetime.state.value.running

    /**
     * A run is caching originals from the camera, the transfer channel playback also needs
     * (A2-54). Other stages (export, upload, share) never hold the camera.
     */
    public val holdsCameraTransfer: Boolean get() = lifetime.state.value.progress?.isCaching == true

    /** Starts a run after the outgoing captured run has fully ended. */
    public fun begin(
        onCancel: (() -> Unit)? = null,
        onComplete: ((MonitorDeliveryBatchOutcome<File>) -> Unit)? = null,
        run: suspend (MonitorDeliveryAdmission, (MonitorDeliveryBatchProgress) -> Unit) -> MonitorDeliveryBatchOutcome<File>,
    ): MonitorDeliveryRunHandle? {
        val outgoing = capturedRun
        val handle = lifetime.beginCaptured(onCancel, { outcome -> onComplete?.invoke(outcome); null },
            cleanupWhenRetired = true) { progress, admission ->
            outgoing?.cancelAndJoin()
            // A superseded run still enters [run], which releases what it was handed (a route lease).
            run(admission, progress).completion()
        }
        capturedRun = handle
        return handle
    }

    /**
     * Remote delivery from the camera network caches every original first, as a run of this
     * owner, and throws unless all are cached (A2-05).
     */
    public suspend fun <R> cacheBeforeInternetHop(
        records: List<R>, originals: MonitorDeliveryOriginalService<R>, source: MonitorDeliveryAdmission,
        filename: (R) -> String, uploadCaption: String?,
    ) {
        val outgoing = capturedRun
        val run = lifetime.beginCaptured { progress, admission ->
            outgoing?.cancelAndJoin()
            MonitorDeliveryModel.cacheOriginals(records, MonitorDeliveryDestination.REMOTE_UPLOAD,
                MonitorDeliveryAdmission { admission.isCurrent() && source.isCurrent() }, originals, filename,
                uploadCaption, progress = progress)
            MonitorDeliveryCompletion(MonitorDeliveryBatchOutcome.Uploaded(""))
        } ?: throw CancellationException("Delivery is closed.")
        capturedRun = run
        run.awaitEnteredCleanup()
        if (!source.isCurrent()) throw CancellationException("Selection is no longer available.")
        // The cache itself is the truth: a cancelled or superseded run leaves clips uncached.
        val missing = records.filter { !originals.available(it) }
        if (missing.isNotEmpty()) {
            throw MonitorDeliveryCacheException(missing.size, missing.any(originals.cameraStoppedResponding))
        }
    }

    /** Announces a refusal through the same outcome toast. */
    public fun fail(message: String) { begin { _, _ -> MonitorDeliveryBatchOutcome.Failed(message) } }
    public fun cancel(): Unit = lifetime.cancel()
    public fun close(): Unit = lifetime.close()

    /**
     * One delivery batch over a source: Photos saves item by item after access is granted, and a
     * remote run skips what its history already has. An accepted route [lease] is restored when
     * the run ends, whatever its destination.
     */
    public suspend fun <R, C, F, H> run(
        records: List<R>, destination: MonitorDeliveryDestination, action: MonitorDeliveryPostExportAction,
        admission: MonitorDeliveryAdmission, source: MonitorDeliverySource<R, C, F>,
        configuration: MonitorDeliveryExportConfiguration<C, F>?, remote: MonitorDeliveryRemoteRun<R>?,
        photos: MonitorDeliveryPhotosService<File>?, photosAuthorization: MonitorDeliveryPhotosAuthorizationService? = null,
        internet: MonitorDeliveryInternetService<H>? = null, lease: H? = null,
        progress: (MonitorDeliveryBatchProgress) -> Unit,
    ): MonitorDeliveryBatchOutcome<File> {
        // Which record each delivered file came from, for the upload of that record.
        val origins = HashMap<File, R>()
        val admitted = if (remote == null) admission
            else MonitorDeliveryAdmission { admission.isCurrent() && remote.admission.isCurrent() && admission.isCurrent() }
        val includeMetadata = configuration?.includeMetadata ?: true
        // A refused run still enters the batch, which releases the lease it was handed.
        try {
            if (admitted.isCurrent()) source.load()
        } catch (failure: Throwable) {
            // The batch was never entered: release the route it would have restored.
            if (lease != null && internet != null) withContext(NonCancellable) { internet.restoreEntered(lease) }
            if (failure is CancellationException) throw failure
            return MonitorDeliveryBatchOutcome.Failed(failure.message ?: failure.toString())
        }
        val outcome = MonitorDeliveryModel.runBatch(
            records = records, destination = destination, action = action, admission = admitted,
            originals = source.originals,
            exporter = MonitorDeliveryExportService(release = { file -> origins.remove(file); source.release(file) },
                prepare = { record, report ->
                    source.prepare(record, configuration, report)?.also { origins[it] = record }
                }),
            share = { files -> MonitorDeliveryShareFiles(files) }, photos = photos,
            photosAuthorization = photosAuthorization,
            upload = remote?.let { remote ->
                MonitorDeliveryUploadService(remote.progressCaption) { file, report ->
                    val record = origins[file] ?: throw CancellationException("Delivery file was released.")
                    remote.upload(record, file, report)
                }
            },
            uploadHistory = remote?.history, reupload = remote?.reupload ?: false,
            internet = internet, initialLease = lease, filename = source.filename,
            artifactFilename = { it.name },
            metadata = { if (includeMetadata) source.metadata(it) else null },
            noPrepared = source.noPrepared, progress = progress)
        val note = remote?.routeNote?.invoke() ?: return outcome
        return when (outcome) {
            is MonitorDeliveryBatchOutcome.Uploaded -> MonitorDeliveryBatchOutcome.Uploaded(listOf(outcome.summary, note).filter { it.isNotEmpty() }.joinToString("; "))
            // One sentence: "Cancelled; camera rejoined.", never "Cancelled.; camera rejoined".
            is MonitorDeliveryBatchOutcome.Failed -> MonitorDeliveryBatchOutcome.Failed(
                "${outcome.message.removeSuffix(".")}; $note".let { if (it.endsWith(".")) it else "$it." })
            else -> outcome
        }
    }
}

/**
 * Some selected originals could not be cached before the camera network was left;
 * [cameraStopped] when the camera stopped answering while they cached.
 */
public class MonitorDeliveryCacheException(public val count: Int, public val cameraStopped: Boolean = false) :
    Exception(
        if (cameraStopped) MonitorDeliveryBatchPolicy.cameraStoppedResponding(count)
        else MonitorDeliveryBatchPolicy.cacheFailure(count))
