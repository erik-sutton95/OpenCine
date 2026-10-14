package com.opencapture.opencine.appkit

import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/** A handle to the existing captured job, never a successor run or an additional scheduler. */
public class MonitorDeliveryRunHandle internal constructor(
    private val work: Job, private val cancelCaptured: () -> Unit,
) {
    public suspend fun awaitEnteredCleanup(): Unit = withContext(NonCancellable) { work.join() }
    public fun cancel() {
        cancelCaptured()
        work.cancel()
    }
    public suspend fun cancelAndJoin() {
        cancel()
        withContext(NonCancellable) { work.join() }
    }
}

/** App-owned completion facts; destinations, files and storage namespaces are not inferred. */
public data class MonitorDeliveryCompletion<O, S>(public val outcome: O,
    public val share: S? = null, public val toast: String? = null)
public data class MonitorDeliveryShare<S>(public val id: UUID, public val payload: S)
public data class MonitorDeliveryState<P, S>(
    public val running: Boolean = false,
    public val progress: P? = null,
    public val share: MonitorDeliveryShare<S>? = null,
    public val toast: String? = null,
    public val expanded: Boolean = false,
    public val localOverlayDepth: Int = 0,
) {
    public val showsLocalOverlay: Boolean get() = localOverlayDepth > 0
    public val showsGlobalChrome: Boolean get() = progress != null && !showsLocalOverlay
}

/** Caller dispatcher owns all operations and publication, including supplied progress callbacks.
 * Call close when releasing this presentation lifetime, before cancelling its supplied scope. */
public class MonitorDeliveryModel<P, O, S>(
    scope: CoroutineScope,
    private val sleep: suspend (Duration) -> Unit = { delay(it) },
    private val releaseShare: (S) -> Unit = {},
) {
    private val owner = CoroutineScope(scope.coroutineContext + SupervisorJob(scope.coroutineContext[Job]))
    private val mutable = MutableStateFlow(MonitorDeliveryState<P, S>())
    public val state: StateFlow<MonitorDeliveryState<P, S>> = mutable.asStateFlow()
    private data class ShareAcknowledgement(val id: UUID, val run: UUID)
    private var shareRun: UUID? = null
    private var pendingShareAcknowledgement: ShareAcknowledgement? = null
    private var run = UUID.randomUUID()
    private var closed = false
    private var work: Job? = null
    private var cancelHandler: (() -> Unit)? = null
    private var toastID = UUID.randomUUID()
    private var toastTask: Job? = null

    public fun begin(
        onCancel: (() -> Unit)? = null,
        onComplete: ((O) -> String?)? = null,
        operation: suspend ((P) -> Unit) -> MonitorDeliveryCompletion<O, S>,
    ) {
        beginAdmitted(onCancel, onComplete) { progress, _ -> operation(progress) }
    }

    public fun beginAdmitted(
        onCancel: (() -> Unit)? = null,
        onComplete: ((O) -> String?)? = null,
        operation: suspend ((P) -> Unit, MonitorDeliveryAdmission) -> MonitorDeliveryCompletion<O, S>,
    ) {
        beginCaptured(onCancel, onComplete, operation)
    }

    /** Returns only this run's job. Old callbacks and direct begin calls keep their signatures. */
    public fun beginCaptured(
        onCancel: (() -> Unit)? = null,
        onComplete: ((O) -> String?)? = null,
        operation: suspend ((P) -> Unit, MonitorDeliveryAdmission) -> MonitorDeliveryCompletion<O, S>,
    ): MonitorDeliveryRunHandle? {
        return beginCaptured(onCancel, onComplete, cleanupWhenRetired = false, operation)
    }

    /**
     * A captured-resource operation reaches cleanup even if retired before job entry. It must
     * honor its stale admission before entering source or native work, including after joins.
     */
    public fun beginCaptured(
        onCancel: (() -> Unit)? = null,
        onComplete: ((O) -> String?)? = null,
        cleanupWhenRetired: Boolean,
        operation: suspend ((P) -> Unit, MonitorDeliveryAdmission) -> MonitorDeliveryCompletion<O, S>,
    ): MonitorDeliveryRunHandle? {
        if (closed) return null
        val previous = work
        val token = UUID.randomUUID()
        run = token
        pendingShareAcknowledgement = null
        cancelHandler = onCancel
        previous?.cancel()
        if (!cleanupWhenRetired && !current(token)) return null
        val entry = CompletableDeferred<Unit>()
        val start = if (cleanupWhenRetired) CoroutineStart.UNDISPATCHED else CoroutineStart.LAZY
        val next = owner.launch(start = start) {
            // Enter undispatched, then wait until running state and the captured job are installed.
            // Cancellation cannot drop this resource cleanup before the operation starts.
            if (cleanupWhenRetired) withContext(NonCancellable) { entry.await() }
            if (!cleanupWhenRetired && !current(token)) return@launch
            val completion = try {
                val operationJob = currentCoroutineContext()[Job]
                operation({ progress ->
                    if (current(token) && state.value.running) publish(token) { it.copy(progress = progress) }
                }, MonitorDeliveryAdmission { operationJob?.isActive == true && current(token) && state.value.running })
            } catch (_: CancellationException) {
                if (current(token)) this@MonitorDeliveryModel.cancel()
                return@launch
            } catch (failure: Throwable) {
                if (current(token)) this@MonitorDeliveryModel.cancel()
                throw failure
            }
            if (!currentCoroutineContext().isActive && current(token)) this@MonitorDeliveryModel.cancel()
            if (!current(token) || !state.value.running) {
                completion.share?.let(releaseShare)
                return@launch
            }
            finish(completion, token, onComplete)
        }
        val admitted = current(token)
        if (admitted) work = next
        if (admitted && publish(token) { it.copy(running = true, progress = null, expanded = false) }) {
            if (!cleanupWhenRetired) next.start()
        } else next.cancel()
        entry.complete(Unit)
        return MonitorDeliveryRunHandle(next) { if (current(token) && state.value.running) cancel() }
    }

    /** Retire first; a cancellation callback can begin another run without outgoing writes. */
    public fun cancel() {
        val previous = work
        val callback = cancelHandler
        val token = UUID.randomUUID()
        run = token
        pendingShareAcknowledgement = null
        work = null
        cancelHandler = null
        previous?.cancel()
        callback?.invoke()
        publish(token) { it.copy(running = false, progress = null, expanded = false) }
    }

    public fun setExpanded(expanded: Boolean) { mutable.value = state.value.copy(expanded = expanded) }
    public fun enterLocalOverlayContext() { mutable.value = state.value.copy(localOverlayDepth = state.value.localOverlayDepth + 1) }
    public fun exitLocalOverlayContext() { mutable.value = state.value.copy(localOverlayDepth = (state.value.localOverlayDepth - 1).coerceAtLeast(0)) }

    public fun clearSharePresentation(id: UUID? = null) {
        val previous = state.value.share ?: return
        if (id != null && id != previous.id) return
        pendingShareAcknowledgement = if (!closed) {
            shareRun?.let { ShareAcknowledgement(previous.id, it) }
        } else null
        shareRun = null
        mutable.value = state.value.copy(share = null)
        releaseShare(previous.payload)
    }

    /** One matching completion, independent of binding/OS dismissal order. */
    public fun completeSharePresentation(id: UUID): Boolean {
        clearSharePresentation(id)
        val acknowledgement = pendingShareAcknowledgement ?: return false
        if (acknowledgement.id != id || !current(acknowledgement.run)) return false
        pendingShareAcknowledgement = null
        return true
    }

    public fun dismissToast() {
        toastID = UUID.randomUUID()
        val identity = toastID
        val previous = toastTask
        toastTask = null
        previous?.cancel()
        if (toastID != identity) return
        mutable.value = state.value.copy(toast = null)
    }

    public fun close() {
        if (closed) return
        closed = true
        cancel()
        dismissToast()
        clearSharePresentation()
        owner.cancel()
    }

    private fun current(token: UUID): Boolean = !closed && run == token

    public companion object {}
    private fun publish(token: UUID, change: (MonitorDeliveryState<P, S>) -> MonitorDeliveryState<P, S>): Boolean {
        if (run != token) return false
        mutable.value = change(state.value)
        return current(token)
    }

    private fun finish(completion: MonitorDeliveryCompletion<O, S>, token: UUID, onComplete: ((O) -> String?)?) {
        work = null
        cancelHandler = null
        pendingShareAcknowledgement = null
        if (!publish(token) { it.copy(running = false, progress = null, expanded = false) }) {
            completion.share?.let(releaseShare)
            return
        }
        val overrideToast = onComplete?.invoke(completion.outcome)
        if (!current(token)) {
            completion.share?.let(releaseShare)
            return
        }
        completion.share?.let { share ->
            val previous = state.value.share
            shareRun = token
            val admitted = publish(token) { it.copy(share = MonitorDeliveryShare(UUID.randomUUID(), share)) }
            previous?.let { releaseShare(it.payload) }
            if (!admitted || !current(token)) return
        }
        (overrideToast ?: completion.toast)?.let { showToast(it, token) }
    }

    private fun showToast(message: String, token: UUID) {
        toastID = UUID.randomUUID()
        val identity = toastID
        val previous = toastTask
        toastTask = null
        previous?.cancel()
        if (!current(token) || toastID != identity) return
        val next = owner.launch(start = CoroutineStart.LAZY) {
            try { sleep(2500.milliseconds) } catch (_: CancellationException) { return@launch }
            if (toastID != identity || closed) return@launch
            toastTask = null
            mutable.value = state.value.copy(toast = null)
        }
        toastTask = next
        if (publish(token) { it.copy(toast = message) }) next.start() else next.cancel()
    }
}
