package com.opencapture.opencine.appkit

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlin.time.Duration

/** Captured native task facts. This value neither schedules nor chooses an operation. */
public class MonitorDeliveryExternalOperation(public val active: () -> Boolean, public val cancel: () -> Unit)
public class MonitorDeliveryExternalTicket<P> internal constructor(internal val operation: MonitorDeliveryExternalOperation?) {
    internal val terminal: CompletableDeferred<String?> = CompletableDeferred()
    internal var report: ((P) -> Unit)? = null
    internal var pendingProgress: P? = null
    internal var callerFinished: Boolean = false
}
public data class MonitorDeliveryPresentationDisplay<P>(
    public val overlay: P? = null, public val toast: String? = null, public val expanded: Boolean = false,
)

/** Existing native/external progress, chrome and toast contexts with captured completion priority. */
public class MonitorDeliveryPresentation<P>(
    scope: CoroutineScope,
    private val isCaching: (P) -> Boolean,
    private val isExternalDelivery: (P) -> Boolean,
    sleep: suspend (Duration) -> Unit = { delay(it) },
) {
    private enum class Intent { NATIVE, EXTERNAL }
    private class NativeTicket
    private val native = MonitorDeliveryModel<P, String?, Unit>(scope, sleep)
    private val external = MonitorDeliveryModel<P, String?, Unit>(scope, sleep)
    private val chrome = MonitorDeliveryModel<Unit, Unit, Unit>(scope, sleep)
    private val notifications = MonitorDeliveryModel<Unit, Unit, Unit>(scope, sleep)
    private val presented = MutableStateFlow<Intent?>(null)
    private var nativeTicket: NativeTicket? = null
    private var ticket: MonitorDeliveryExternalTicket<P>? = null
    private var closed = false
    public val display: StateFlow<MonitorDeliveryPresentationDisplay<P>> = combine(
        native.state, external.state, chrome.state, notifications.state, presented,
    ) { n, e, c, t, intent ->
        MonitorDeliveryPresentationDisplay(when (intent) { Intent.NATIVE -> n.progress; Intent.EXTERNAL -> e.progress; null -> null }, t.toast, c.expanded)
    }.stateIn(scope, SharingStarted.Eagerly, MonitorDeliveryPresentationDisplay())
    public val overlayState: P? get() = when (presented.value) {
        Intent.NATIVE -> native.state.value.progress; Intent.EXTERNAL -> external.state.value.progress; null -> null
    }
    public val completionToast: String? get() = notifications.state.value.toast
    public var isExpanded: Boolean
        get() = chrome.state.value.expanded
        set(value) { chrome.setExpanded(value) }
    public val nativeRunning: Boolean get() = native.state.value.running
    public val nativeState: StateFlow<MonitorDeliveryState<P, Unit>> get() = native.state
    public fun beginNative(operation: suspend ((P) -> Unit) -> String?) {
        beginNativeCaptured { report, _ -> operation(report) }
    }
    public fun beginNativeCaptured(operation: suspend ((P) -> Unit, MonitorDeliveryAdmission) -> String?): MonitorDeliveryRunHandle? {
        if (closed) return null
        val captured = NativeTicket(); nativeTicket = captured
        presented.value = Intent.NATIVE
        if (nativeTicket !== captured || closed) return null
        chrome.setExpanded(false)
        if (nativeTicket !== captured || closed) return null
        return native.beginCaptured(onComplete = { message ->
            if (nativeTicket === captured && !closed) {
                presented.value = null
                if (nativeTicket !== captured || closed) return@beginCaptured null
                chrome.setExpanded(false)
                if (nativeTicket === captured && !closed) message?.let(::showToast)
            }
            null
        }) { report, admission ->
            val operationJob = currentCoroutineContext()[Job]
            val message = operation({ progress ->
                if (!closed && nativeTicket === captured && operationJob?.isActive == true) {
                    presented.value = Intent.NATIVE
                    report(progress)
                }
            }, admission)
            MonitorDeliveryCompletion(message)
        }
    }
    public fun trackExternalDelivery(operation: MonitorDeliveryExternalOperation?): MonitorDeliveryExternalTicket<P> {
        val captured = MonitorDeliveryExternalTicket<P>(operation)
        if (closed) { captured.callerFinished = true; return captured }
        captured.pendingProgress = overlayState.takeIf { presented.value == Intent.EXTERNAL }
        ticket = captured
        external.begin(onCancel = { if (!captured.callerFinished) captured.operation?.cancel?.invoke() }, onComplete = { message ->
            if (ticket === captured) {
                presented.value = null
                if (ticket !== captured || closed) return@begin null
                chrome.setExpanded(false)
                if (ticket === captured && !closed) message?.let(::showToast)
            }
            null
        }) { report ->
            captured.report = report; captured.pendingProgress?.let(report); captured.pendingProgress = null
            MonitorDeliveryCompletion(captured.terminal.await())
        }
        return captured
    }
    public fun finishExternalDelivery(captured: MonitorDeliveryExternalTicket<P>) {
        if (ticket !== captured || closed) return
        captured.callerFinished = true
        val progress = overlayState
        if (progress != null && isCaching(progress) && !nativeRunning && ticket === captured && !closed) {
            presented.value = null
            if (ticket !== captured || closed) return
            chrome.setExpanded(false)
            if (ticket === captured && !closed) external.cancel()
        }
    }
    public fun publishCache(captured: MonitorDeliveryExternalTicket<P>, progress: P) {
        if (closed || ticket !== captured) return
        presented.value = Intent.EXTERNAL
        val report = captured.report
        if (report == null) captured.pendingProgress = progress else report(progress)
    }
    public fun publishExternalDelivery(captured: MonitorDeliveryExternalTicket<P>, progress: P) {
        if (!closed && ticket === captured && !nativeRunning) publishCache(captured, progress)
    }
    public fun completeExternalDelivery(captured: MonitorDeliveryExternalTicket<P>, message: String?) {
        if (!closed && ticket === captured && !nativeRunning) captured.terminal.complete(message)
    }
    public fun noteExternalIdle(captured: MonitorDeliveryExternalTicket<P>) {
        if (closed || ticket !== captured || nativeRunning || captured.operation?.active?.invoke() == true) return
        if (closed || ticket !== captured || nativeRunning) return
        val progress = overlayState
        if (progress != null && isExternalDelivery(progress) && !closed && ticket === captured && !nativeRunning) {
            presented.value = null
            if (ticket !== captured || closed) return
            chrome.setExpanded(false)
            if (ticket === captured && !closed) external.cancel()
        }
    }
    public fun showToast(message: String) { if (!closed) notifications.begin { MonitorDeliveryCompletion(Unit, toast = message) } }
    public fun dismissToast() { notifications.dismissToast() }
    public fun cancel() {
        val retiringExternal = ticket
        nativeTicket = null; ticket = null; presented.value = null
        if (nativeTicket == null && ticket == null) chrome.setExpanded(false)
        if (nativeTicket == null) native.cancel()
        if (ticket == null) external.cancel()
        else if (retiringExternal?.callerFinished == false) retiringExternal.operation?.cancel?.invoke()
    }
    public fun close() {
        if (closed) return
        closed = true; cancel(); native.close(); external.close(); chrome.close(); notifications.close()
    }
}
