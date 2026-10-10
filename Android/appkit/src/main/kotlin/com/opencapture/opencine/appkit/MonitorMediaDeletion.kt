package com.opencapture.opencine.appkit

import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.util.UUID

/** Preparation retires a catalog while retaining only its consumed deletion claim. */
public enum class MonitorMediaDeletionPreparation { PRESERVE_GALLERY, RETIRE_GALLERY }
public enum class MonitorMediaDeleteAcknowledgement { REMOVED, RETAINED, UNKNOWN }
public data class MonitorMediaDeletionProgress(
    public val completed: Int, public val total: Int, public val selectedCount: Int,
)
public data class MonitorMediaDeletionTarget<V, L>(public val value: V, public val locations: List<L>, public val canRemove: Boolean = true)
/** One native ACK and one atomic source commit; refused/unknown copies remain survivors. */
public class MonitorMediaDeletionPort<V, L>(
    public val remove: suspend (L) -> MonitorMediaDeleteAcknowledgement,
    public val commit: suspend (V, List<L>) -> Boolean,
    public val finish: suspend () -> Unit = {},
) {
    internal var completed: ((Int) -> Unit)? = null
}

internal class MonitorMediaDeletionReturnGate { var retired = false }

/** A finished claim permits presentation return only, never another SDK command. */
public class MonitorMediaDeletionCompletion internal constructor(public val claim: UUID,
    public val removedCount: Int, public val admission: MonitorMediaLibraryActionToken,
    private val directory: MonitorMediaCacheDirectory, private val generation: Long,
    private val gate: MonitorMediaDeletionReturnGate,
    private val admitted: () -> Boolean) {
    public val isCurrent: Boolean get() {
        if (gate.retired || directory.generation != generation) return false
        val available = admitted()
        return available && !gate.retired && directory.generation == generation
    }
    /** Picture retirement revokes return even after entered native work has finished. */
    public fun retire(): Unit { gate.retired = true }
}

/** One accepted action, bound to its original cache/source and explicit preparation token. */
public class MonitorMediaLibraryDeletionAuthority internal constructor(
    internal val owner: UUID,
    public val key: MonitorMediaLibraryIOKey,
    public val directory: MonitorMediaCacheDirectory,
    token: MonitorMediaLibraryActionToken,
    internal val sourceCurrent: () -> Boolean,
    private val admitted: (MonitorMediaLibraryActionToken) -> Boolean,
) {
    public val id: UUID = UUID.randomUUID()
    public val generation: Long = directory.generation
    public var actionToken: MonitorMediaLibraryActionToken = token
        private set
    public var isPrepared: Boolean = false
        private set
    private var consumed = false
    internal var clearsSelection: Boolean = false
    private var retired = false
    private val returnGate = MonitorMediaDeletionReturnGate()
    private var finishing: (() -> Boolean)? = null
    public var completion: MonitorMediaDeletionCompletion? = null
        private set
    public val isCurrent: Boolean get() {
        val token = actionToken
        if (retired || directory.generation != generation) return false
        val allowed = admitted(token)
        return allowed && !retired && actionToken == token && directory.generation == generation
    }
    /** Logical retirement does not cancel an already-entered native removal. */
    public fun retire(): Unit { retired = true; returnGate.retired = true }
    internal fun expireIO() { retired = true }
    public val isCompleting: Boolean get() {
        val current = finishing ?: return false
        if (returnGate.retired || directory.generation != generation) return false
        val available = current()
        return available && !returnGate.retired && directory.generation == generation
    }
    internal fun beginCompletion(current: () -> Boolean) { if (isCurrent) finishing = current }
    internal fun sealCompletion(removed: Int, admission: MonitorMediaLibraryActionToken) {
        val current = finishing ?: return
        if (isCompleting) completion = MonitorMediaDeletionCompletion(id, removed, admission, directory, generation, returnGate, current)
    }
    internal fun consume(): Boolean {
        if (consumed || !isCurrent) return false
        consumed = true
        return isCurrent
    }
    internal fun prepare(token: MonitorMediaLibraryActionToken): Unit { actionToken = token; isPrepared = true }
}

/** Runs within the existing Library operation, with checks around native suspension/commit. */
public object MonitorMediaOrderedDeletion {
    public suspend fun <V, L> run(targets: List<MonitorMediaDeletionTarget<V, L>>, selectedCount: Int,
        ifCurrent: () -> Boolean, port: MonitorMediaDeletionPort<V, L>,
        progress: (MonitorMediaDeletionProgress) -> Unit): Int {
        if (!currentCoroutineContext().isActive || !ifCurrent()) return 0
        progress(MonitorMediaDeletionProgress(0, targets.size, selectedCount))
        var removed = 0
        var completed = 0
        for (target in targets) {
            if (!currentCoroutineContext().isActive || !ifCurrent()) return removed
            if (!target.canRemove) continue
            val survivors = mutableListOf<L>()
            for (location in target.locations) {
                if (!currentCoroutineContext().isActive || !ifCurrent()) return removed
                val result = withContext(NonCancellable) { port.remove(location) }
                if (!currentCoroutineContext().isActive || !ifCurrent()) return removed
                if (result != MonitorMediaDeleteAcknowledgement.REMOVED) survivors.add(location)
            }
            if (!currentCoroutineContext().isActive || !ifCurrent()) return removed
            if (port.commit(target.value, survivors.toList())) removed += 1
            port.completed?.invoke(removed)
            if (!currentCoroutineContext().isActive || !ifCurrent()) return removed
            completed += 1
            progress(MonitorMediaDeletionProgress(completed, targets.size, selectedCount))
        }
        if (!currentCoroutineContext().isActive || !ifCurrent()) return removed
        port.completed?.invoke(removed)
        if (!currentCoroutineContext().isActive || !ifCurrent()) return removed
        port.finish()
        return removed
    }
}
