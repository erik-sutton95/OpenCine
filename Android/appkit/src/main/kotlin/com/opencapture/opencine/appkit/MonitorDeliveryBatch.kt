package com.opencapture.opencine.appkit

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

public data class MonitorDeliveryCachedOriginals<R>(public val ready: List<R>, public val uncached: Int)

/** Cache-only part of the same admitted run; missing receipts remain explicit and ordered. */
public suspend fun <R> MonitorDeliveryModel.Companion.cacheOriginals(
    records: List<R>, destination: MonitorDeliveryDestination,
    admission: MonitorDeliveryAdmission, originals: MonitorDeliveryOriginalService<R>,
    filename: (R) -> String, uploadCaption: String? = null,
    sleep: suspend (Long) -> Unit = { delay(it) }, progress: (MonitorDeliveryBatchProgress) -> Unit,
): MonitorDeliveryCachedOriginals<R>? {
    val operationJob = currentCoroutineContext()[kotlinx.coroutines.Job]
    fun accepts() = operationJob?.isActive == true && admission.isCurrent() && operationJob.isActive
    val toCache = mutableListOf<R>()
    for (record in records) {
        if (!accepts()) return null
        val available = originals.available(record)
        if (!accepts()) return null
        if (!available) toCache += record
    }
    var uncached = 0
    for ((index, record) in toCache.withIndex()) {
        if (!accepts()) return null
        var value = MonitorDeliveryBatchProgress(destination, toCache.size, index + 1, 0.0,
            isCaching = true, filename = filename(record), uploadCaption = uploadCaption, stage = MonitorDeliveryBatchProgress.Stage.CACHING)
        progress(value)
        if (!accepts()) return null
        coroutineScope {
            var active = true
            val mirror = launch {
                while (active && accepts()) {
                    sleep(200)
                    if (!active || !accepts()) return@launch
                    val fraction = originals.progress(record)
                    if (!active || !accepts()) return@launch
                    if (fraction != null) { value = value.copy(clipFraction = fraction); progress(value) }
                }
            }
            try { originals.acquire(record) } finally { active = false; mirror.cancel() }
        }
        if (!accepts()) return null
        val available = originals.available(record)
        if (!accepts()) return null
        if (!available) uncached += 1
    }
    val ready = mutableListOf<R>()
    for (record in records) {
        if (!accepts()) return null
        val available = originals.available(record)
        if (!accepts()) return null
        if (available) ready += record
    }
    return MonitorDeliveryCachedOriginals(ready, uncached)
}

/** Ordered preparation within the existing admitted delivery run; no cache or IO owner is created. */
public suspend fun <R, A, H> MonitorDeliveryModel.Companion.runBatch(
    records: List<R>, destination: MonitorDeliveryDestination, action: MonitorDeliveryPostExportAction,
    admission: MonitorDeliveryAdmission, originals: MonitorDeliveryOriginalService<R>,
    exporter: MonitorDeliveryExportService<R, A>, share: ((List<A>) -> MonitorDeliveryShareFiles<A>)?,
    photos: MonitorDeliveryPhotosService<A>?, upload: MonitorDeliveryUploadService<A>? = null,
    internet: MonitorDeliveryInternetService<H>? = null, initialLease: H? = null,
    filename: (R) -> String, artifactFilename: (A) -> String? = { null }, metadata: (List<R>) -> String? = { null },
    noPrepared: (List<R>) -> String? = { null },
    policy: MonitorDeliveryBatchPolicy = MonitorDeliveryBatchPolicy(),
    sleep: suspend (Long) -> Unit = { delay(it) }, progress: (MonitorDeliveryBatchProgress) -> Unit,
): MonitorDeliveryBatchOutcome<A> {
    return runBatch(
        records = records, destination = destination, action = action, admission = admission,
        originals = originals, exporter = exporter, share = share, photos = photos,
        photosAuthorization = null, upload = upload, internet = internet, initialLease = initialLease,
        filename = filename, artifactFilename = artifactFilename, metadata = metadata,
        noPrepared = noPrepared, policy = policy, sleep = sleep, progress = progress)
}

public suspend fun <R, A, H> MonitorDeliveryModel.Companion.runBatch(
    records: List<R>, destination: MonitorDeliveryDestination, action: MonitorDeliveryPostExportAction,
    admission: MonitorDeliveryAdmission, originals: MonitorDeliveryOriginalService<R>,
    exporter: MonitorDeliveryExportService<R, A>, share: ((List<A>) -> MonitorDeliveryShareFiles<A>)?,
    photos: MonitorDeliveryPhotosService<A>?, photosAuthorization: MonitorDeliveryPhotosAuthorizationService?, upload: MonitorDeliveryUploadService<A>? = null,
    internet: MonitorDeliveryInternetService<H>? = null, initialLease: H? = null,
    filename: (R) -> String, artifactFilename: (A) -> String? = { null }, metadata: (List<R>) -> String? = { null },
    noPrepared: (List<R>) -> String? = { null },
    policy: MonitorDeliveryBatchPolicy = MonitorDeliveryBatchPolicy(),
    sleep: suspend (Long) -> Unit = { delay(it) }, progress: (MonitorDeliveryBatchProgress) -> Unit,
): MonitorDeliveryBatchOutcome<A> {
    val operationJob = currentCoroutineContext()[kotlinx.coroutines.Job]
    fun accepts() = operationJob?.isActive == true && admission.isCurrent() && operationJob.isActive
    fun cancelled() = MonitorDeliveryBatchOutcome.Failed<A>("Cancelled.")
    var lease = initialLease
    val retainedArtifacts = mutableListOf<A>()
    try {
        if (lease != null) {
            val captured = lease
            if (internet == null || !accepts() ||
                !internet.owns(captured) || !accepts()) return cancelled()
        }
        if (destination == MonitorDeliveryDestination.NATIVE_SHARE && action == MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS && photosAuthorization != null) {
            if (!accepts()) return cancelled()
            val pending = photosAuthorization.isPending()
            if (!accepts()) return cancelled()
            if (pending) {
                progress(MonitorDeliveryBatchProgress(destination, maxOf(records.size, 1), 1, 0.0,
                    stage = MonitorDeliveryBatchProgress.Stage.AWAITING_PHOTOS_ACCESS))
                if (!accepts()) return cancelled()
            }
            photosAuthorization.authorize()
            if (!accepts()) return cancelled()
        }
        val cached = cacheOriginals(records, destination, admission, originals, filename,
            upload?.progressCaption, sleep, progress) ?: return cancelled()
        val ready = cached.ready
        val uncached = cached.uncached
        if (ready.isEmpty()) return MonitorDeliveryBatchOutcome.Failed(
            if (uncached > 0) policy.cacheFailure(uncached) else policy.emptySelection)
        if (destination == MonitorDeliveryDestination.REMOTE_UPLOAD) {
            if (upload == null) return MonitorDeliveryBatchOutcome.Failed("Upload is unavailable.")
            if (internet != null) {
                if (!accepts()) return cancelled()
                val needsHop = internet.needsHop()
                if (!accepts()) return cancelled()
                if (needsHop) {
                    val next = lease ?: internet.begin()
                    lease = next
                    if (!accepts() || !internet.owns(next) || !accepts()) return cancelled()
                    var value = MonitorDeliveryBatchProgress(destination, ready.size, 1, 0.0,
                        isSwitchingNetworks = true, uploadCaption = upload?.progressCaption, stage = MonitorDeliveryBatchProgress.Stage.SWITCHING_NETWORKS)
                    progress(value)
                    if (!accepts()) return cancelled()
                    val online = internet.wait(next)
                    if (!accepts() || !internet.owns(next) || !accepts()) return cancelled()
                    value = value.copy(isSwitchingNetworks = false, stage = MonitorDeliveryBatchProgress.Stage.PREPARING)
                    progress(value)
                    if (!accepts()) return cancelled()
                    if (!online) return MonitorDeliveryBatchOutcome.Failed(policy.internetFailure)
                }
            }
        }
        val prepared = mutableListOf<A>()
        var uploaded = 0; var skipped = 0; var failed = 0; var firstFailure: String? = null
        for ((index, record) in ready.withIndex()) {
            if (!accepts()) return cancelled()
            var active = true
            var value = MonitorDeliveryBatchProgress(destination, ready.size, index + 1, 0.0, filename = filename(record), uploadCaption = upload?.progressCaption)
            progress(value)
            if (!accepts()) return cancelled()
            try {
                val artifact = try {
                    exporter.prepare(record) { fraction ->
                        if (active && accepts()) {
                            value = value.copy(stage = MonitorDeliveryBatchProgress.Stage.EXPORTING,
                                clipFraction = if (destination == MonitorDeliveryDestination.REMOTE_UPLOAD) fraction * 0.45 else fraction)
                            progress(value)
                        }
                    }
                } finally { active = false }
                if (artifact != null) retainedArtifacts += artifact
                if (!accepts()) return cancelled()
                if (artifact == null) { skipped += 1; continue }
                if (destination == MonitorDeliveryDestination.REMOTE_UPLOAD && upload != null) {
                    var uploading = true
                    try {
                        upload.upload(artifact) { fraction ->
                            if (uploading && accepts()) {
                                value = value.copy(stage = MonitorDeliveryBatchProgress.Stage.UPLOADING, clipFraction = 0.45 + fraction * 0.55)
                                progress(value)
                            }
                        }
                    } finally { uploading = false }
                    if (!accepts()) return cancelled()
                    uploaded += 1
                } else {
                    prepared += artifact; value = value.copy(clipFraction = 1.0); progress(value)
                }
            } catch (failure: Throwable) {
                active = false
                if (!accepts() || failure is CancellationException) return cancelled()
                if (destination == MonitorDeliveryDestination.NATIVE_SHARE && policy.behavior.nativeFailures == MonitorDeliveryItemFailurePolicy.STOP)
                    return MonitorDeliveryBatchOutcome.Failed(failure.message ?: failure.toString())
                failed += 1; if (firstFailure == null) firstFailure = failure.message ?: failure.toString()
            }
        }
        if (!accepts()) return cancelled()
        if (destination == MonitorDeliveryDestination.REMOTE_UPLOAD) {
            if (policy.behavior.singleUploadFailureUsesDetail && ready.size == 1 && firstFailure != null) return MonitorDeliveryBatchOutcome.Failed(firstFailure)
            val parts = buildList {
                if (uploaded > 0) add("$uploaded uploaded")
                if (skipped > 0) add("$skipped skipped")
                if (uncached > 0) add("$uncached not cached")
                if (failed > 0) add("$failed failed")
            }.joinToString(", ")
            if (failed > 0) return MonitorDeliveryBatchOutcome.Failed(parts)
            if (uploaded == 0 && !policy.behavior.emptyUploadSucceeds) return MonitorDeliveryBatchOutcome.Failed(
                if (skipped > 0) noPrepared(ready) ?: policy.noPrepared ?: policy.emptySelection else parts.ifEmpty { "Nothing to upload." })
            return MonitorDeliveryBatchOutcome.Uploaded(parts.ifEmpty { "Nothing to upload." })
        }
        if (prepared.isEmpty()) return MonitorDeliveryBatchOutcome.Failed(firstFailure ?: noPrepared(ready) ?: policy.noPrepared ?: policy.emptySelection)
        if (action == MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS) {
            if (photos == null) return MonitorDeliveryBatchOutcome.Failed("Saving to Photos is unavailable.")
            val count = when (photos) {
                is MonitorDeliveryPhotosService.Batch -> photos.save(prepared)
                is MonitorDeliveryPhotosService.PerItem -> {
                    var saved = 0; var rejected = 0
                    for ((index, artifact) in prepared.withIndex()) {
                        if (!accepts()) return cancelled()
                        progress(MonitorDeliveryBatchProgress(destination, prepared.size, index + 1, 1.0,
                            filename = artifactFilename(artifact), stage = MonitorDeliveryBatchProgress.Stage.SAVING))
                        if (!accepts()) return cancelled()
                        try {
                            val accepted = photos.save(artifact)
                            if (!accepts()) return cancelled()
                            if (accepted) saved += 1 else rejected += 1
                        } catch (failure: Throwable) {
                            if (!accepts() || failure is CancellationException) return cancelled()
                            if (policy.behavior.photosFailures == MonitorDeliveryItemFailurePolicy.STOP) throw failure
                            rejected += 1
                        }
                    }
                    val failure = policy.photosFailure(saved, rejected)
                    if (!accepts()) return cancelled()
                    if (failure != null) return MonitorDeliveryBatchOutcome.Failed(failure)
                    saved
                }
            }
            if (!accepts()) return cancelled()
            return MonitorDeliveryBatchOutcome.SavedToPhotos(count)
        }
        if (share == null) return MonitorDeliveryBatchOutcome.Failed("Sharing is unavailable.")
        val staged = share(prepared)
        val text = if (accepts()) {
            val note = policy.nativeSummary(MonitorDeliveryBatchCounts(prepared.size, uploaded, skipped, failed, uncached))
            val originalText = if (accepts()) metadata(ready) else null
            if (note == null) originalText else listOfNotNull(note, originalText).filter { it.isNotEmpty() }.joinToString("\n").ifEmpty { null }
        } else null
        return MonitorDeliveryBatchOutcome.Share(staged.urls, text, staged.cleanup)
    } catch (failure: Throwable) {
        return if (!accepts() || failure is CancellationException) cancelled()
            else MonitorDeliveryBatchOutcome.Failed(failure.message ?: failure.toString())
    } finally {
        val enteredArtifacts = retainedArtifacts.toList()
        retainedArtifacts.clear()
        val enteredLease = lease
        lease = null
        withContext(NonCancellable) {
            try {
                for (artifact in enteredArtifacts) runCatching { exporter.release(artifact) }
            } finally {
                if (enteredLease != null && internet != null) internet.restoreEntered(enteredLease)
            }
        }
    }
}
