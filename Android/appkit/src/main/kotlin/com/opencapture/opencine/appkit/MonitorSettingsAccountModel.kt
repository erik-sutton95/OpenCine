package com.opencapture.opencine.appkit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Captures a native route without owning network joins or credentials. */
public enum class MonitorSettingsInternetCleanup { ON_FINISH, ON_RETIRE }
public class MonitorSettingsInternetLease(
    internal val isCurrent: () -> Boolean,
    internal val wait: suspend () -> Boolean,
    internal val restore: suspend () -> Unit,
    internal val cleanup: MonitorSettingsInternetCleanup = MonitorSettingsInternetCleanup.ON_FINISH,
)

/** Account identity survives a camera disconnect caused by an admitted internet hop. */
public class MonitorSettingsAccountActions(
    internal val identity: Any,
    internal val isCurrent: () -> Boolean,
    internal val requiresInternetConsent: Boolean?,
    internal val connect: suspend () -> Unit,
    internal val disconnect: () -> Unit,
    internal val beginInternet: (suspend (() -> Boolean) -> MonitorSettingsInternetLease?)? = null,
    internal val internetFailure: String? = null,
)
public data class MonitorSettingsAccountState(
    public val busy: Boolean = false,
    public val confirmationPresented: Boolean = false,
    public val failed: Boolean = false,
    public val failure: String? = null,
    public val accountRevision: Long = 0,
)

/** One account operation across a planned settings rehost, using the existing native route. */
public class MonitorSettingsAccountModel(private val scope: CoroutineScope) {
    private class Confirmation(val source: MonitorSettingsAccountActions, val generation: Long)
    private class Run(val source: MonitorSettingsAccountActions, val generation: Long) { var task: Job? = null }
    private val mutable = MutableStateFlow(MonitorSettingsAccountState())
    public val state: StateFlow<MonitorSettingsAccountState> = mutable.asStateFlow()
    private var source: MonitorSettingsAccountActions? = null
    private var generation: Long = 0
    private var confirmation: Confirmation? = null
    private var run: Run? = null
    private var retainedLease: MonitorSettingsInternetLease? = null

    public fun bind(next: MonitorSettingsAccountActions): Unit {
        if (source?.identity == next.identity) { source = next; return }
        generation += 1; source = next; confirmation = null
        val outgoing = run; run = null
        val cleanup = retainedLease; retainedLease = null
        mutable.value = MonitorSettingsAccountState()
        outgoing?.task?.cancel()
        restoreEntered(cleanup)
    }
    public fun requestSignIn(): Unit {
        val revision = generation
        val captured = source ?: return
        if (mutable.value.busy || !admits(captured, revision)) return
        if (captured.requiresInternetConsent == true) {
            confirmation = Confirmation(captured, revision)
            mutable.value = mutable.value.copy(confirmationPresented = true)
        } else start(captured, revision, false)
    }
    public fun confirmSignIn(): Unit {
        val captured = confirmation
        cancelConfirmation()
        if (captured != null) start(captured.source, captured.generation, true)
    }
    public fun cancelConfirmation(): Unit {
        confirmation = null
        mutable.value = mutable.value.copy(confirmationPresented = false)
    }
    public fun signOut(): Unit {
        val captured = source ?: return
        val revision = generation
        if (mutable.value.busy || !admits(captured, revision)) return
        captured.disconnect()
        // Entered logout may retire its own native receipt. Only this harmless reread stamp
        // is published afterwards, and it cannot address a replacement account owner.
        if (generation == revision && source?.identity == captured.identity) {
            mutable.value = mutable.value.copy(accountRevision = mutable.value.accountRevision + 1)
        }
    }
    public fun dismissError(): Unit { mutable.value = mutable.value.copy(failed = false, failure = null) }
    public fun retire(): Unit {
        generation += 1; source = null; confirmation = null
        val outgoing = run; run = null
        val cleanup = retainedLease; retainedLease = null
        mutable.value = MonitorSettingsAccountState()
        outgoing?.task?.cancel()
        restoreEntered(cleanup)
    }
    private fun start(captured: MonitorSettingsAccountActions, revision: Long, overInternet: Boolean) {
        if (mutable.value.busy || !admits(captured, revision)) return
        val operation = Run(captured, revision)
        run = operation
        val job = scope.launch(start = CoroutineStart.LAZY) {
            var lease: MonitorSettingsInternetLease? = null
            var failed = false
            var failure: String? = null
            try {
                if (overInternet) {
                    val begin = captured.beginInternet
                    if (!admits(operation) || begin == null) {
                        failed = true; failure = captured.internetFailure
                    } else {
                        lease = begin { admits(operation) }
                        val entered = lease
                        if (entered == null) { failed = true; failure = captured.internetFailure }
                        else {
                            val online = if (admits(operation, entered)) entered.wait() else false
                            if (admits(operation, entered)) {
                                if (online) captured.connect() else { failed = true; failure = captured.internetFailure }
                            }
                        }
                    }
                } else if (admits(operation)) captured.connect()
            } catch (error: Exception) { failed = true; failure = error.message }
            finally {
                // Entered cleanup addresses only this captured native lease, including after Back.
                lease?.let { entered ->
                    if (entered.cleanup == MonitorSettingsInternetCleanup.ON_RETIRE && !failed && admits(operation, entered)) {
                        val previous = retainedLease
                        retainedLease = entered
                        if (previous !== entered) restoreEntered(previous)
                    } else withContext(NonCancellable) { entered.restore() }
                }
                finish(operation, failed, failure)
            }
        }
        operation.task = job
        mutable.value = mutable.value.copy(busy = true, failed = false, failure = null)
        if (run === operation && generation == revision) job.start() else job.cancel()
    }
    private fun admits(captured: MonitorSettingsAccountActions, revision: Long): Boolean {
        if (generation != revision || source?.identity != captured.identity) return false
        val admitted = captured.isCurrent()
        return admitted && generation == revision && source?.identity == captured.identity
    }
    private fun admits(operation: Run): Boolean {
        if (run !== operation || operation.task?.isActive != true) return false
        val admitted = admits(operation.source, operation.generation)
        return admitted && run === operation && operation.task?.isActive == true
    }
    private fun admits(operation: Run, lease: MonitorSettingsInternetLease): Boolean {
        if (!admits(operation)) return false
        val current = lease.isCurrent()
        return current && run === operation && generation == operation.generation &&
            source?.identity == operation.source.identity && operation.task?.isActive == true
    }
    private fun finish(operation: Run, failed: Boolean, failure: String?) {
        if (!admits(operation)) return
        run = null; operation.task = null
        mutable.value = mutable.value.copy(busy = false, failed = failed, failure = failure,
            accountRevision = mutable.value.accountRevision + 1)
    }
    private fun restoreEntered(lease: MonitorSettingsInternetLease?) {
        if (lease == null) return
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            withContext(NonCancellable) { lease.restore() }
        }
    }
}
