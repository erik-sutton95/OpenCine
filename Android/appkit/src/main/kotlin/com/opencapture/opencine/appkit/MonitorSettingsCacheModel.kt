package com.opencapture.opencine.appkit

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.ensureActive

/** Namespace and shell lifetime remain independent of cache content revisions. */
public data class MonitorSettingsCacheIdentity(public val namespace: String, public val source: String?)

/** Bounded captured operations on the existing cache IO owner. */
public class MonitorSettingsCacheSource(
    public val identity: MonitorSettingsCacheIdentity,
    public val revision: Long,
    internal val isCurrent: () -> Boolean,
    internal val count: suspend () -> Long,
    internal val clear: suspend () -> Unit,
    internal val clearSummary: (() -> String?)? = null,
)

/**
 * The settings cache source over this library's own directory, so Settings counts and clears exactly
 * what the gallery writes. [value] is the observed library state the source is captured from.
 */
public fun <P> MonitorMediaLibraryModel<P>.settingsCacheSource(
    value: MonitorMediaLibraryState<P> = state.value,
): MonitorSettingsCacheSource {
    val admission = actionToken
    val revision = value.cacheRevision
    return MonitorSettingsCacheSource(
        MonitorSettingsCacheIdentity(cache.directory.root.absolutePath, value.lifetimeToken.toString()),
        revision,
        isCurrent = { isCurrent(admission) && state.value.cacheRevision == revision },
        count = { cache.directory.totalByteCount() },
        clear = { clearCache() },
    )
}
/** Settings scope over every camera owned by the shared root, keeping the current library's fencing. */
public fun <P> MonitorMediaLibraryModel<P>.settingsCacheSource(
    cacheRoot: MonitorMediaCacheRoot, value: MonitorMediaLibraryState<P> = state.value,
): MonitorSettingsCacheSource = allCameraSettingsCacheSource(cacheRoot.root, cacheRoot::cachedDirectories, value)

/** Settings scope over every camera owned by the storage registry under one declared parent. */
public fun <P> MonitorMediaLibraryModel<P>.settingsCacheSource(
    storage: MonitorMediaCacheStorage, parent: java.io.File, value: MonitorMediaLibraryState<P> = state.value,
): MonitorSettingsCacheSource = allCameraSettingsCacheSource(parent, { storage.directories(parent) }, value)

internal fun <P> MonitorMediaLibraryModel<P>.allCameraSettingsCacheSource(
    parent: java.io.File, directories: () -> List<MonitorMediaCacheDirectory>, value: MonitorMediaLibraryState<P>,
    clearOtherDirectory: suspend (MonitorMediaCacheDirectory) -> Unit = { it.clear(emptyList()) },
): MonitorSettingsCacheSource {
    val admission = actionToken
    val revision = value.cacheRevision
    val observedLifetimeIsCurrent = value.lifetimeToken == admission.lifetime
    return MonitorSettingsCacheSource(
        MonitorSettingsCacheIdentity(parent.absolutePath, value.lifetimeToken.toString()), revision,
        // A content revision renews the readout, while this parent scope retains its action authority.
        isCurrent = { observedLifetimeIsCurrent && isCurrent(admission) },
        count = { directories().sumOf { it.totalByteCount() } },
        clear = {
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            if (!observedLifetimeIsCurrent || !isCurrent(admission)) {
                throw com.opencapture.opencine.media.MediaServiceException(com.opencapture.opencine.media.MediaServiceFailure.RETIRED)
            }
            val captured = directories()
            clearCache(preservingMetadata = false)
            for (directory in captured) {
                kotlinx.coroutines.currentCoroutineContext().ensureActive()
                if (!isCurrent(admission)) {
                    throw com.opencapture.opencine.media.MediaServiceException(com.opencapture.opencine.media.MediaServiceFailure.RETIRED)
                }
                if (directory.root.absolutePath != cache.directory.root.absolutePath) clearOtherDirectory(directory)
            }
        },
    )
}
public data class MonitorSettingsCacheState(
    public val bytes: Long? = null,
    public val clearing: Boolean = false,
    public val clearFailed: Boolean = false,
    public val confirmationPresented: Boolean = false,
    public val readFailed: Boolean = false,
    public val failure: String? = null,
    public val clearSummary: String? = null,
)

/** Shared presentation/action retirement; no cache directory or IO ownership. */
public class MonitorSettingsCacheModel(private val scope: CoroutineScope) {
    private val mutable = MutableStateFlow(MonitorSettingsCacheState())
    public val state: StateFlow<MonitorSettingsCacheState> = mutable.asStateFlow()
    private var source: MonitorSettingsCacheSource? = null
    private var sourceRevision: Long = 0
    private var confirmation: MonitorSettingsCacheSource? = null
    private var countTask: Job? = null
    private var clearTask: Job? = null
    private var countOwner: Any? = null
    private var clearOwner: Any? = null
    public fun refresh(next: MonitorSettingsCacheSource): Unit {
        val changed = source?.identity != next.identity
        val oldCount = countTask
        val oldClear = if (changed) clearTask else null
        if (changed) { clearOwner = null; clearTask = null; confirmation = null }
        sourceRevision += 1
        val revision = sourceRevision
        source = next
        val owner = Any(); countOwner = owner
        val task = scope.launch(start = CoroutineStart.LAZY) {
            if (!isActive || !admitsCount(next, owner)) return@launch
            try {
                val bytes = next.count()
                if (isActive && admitsCount(next, owner)) {
                    mutable.value = mutable.value.copy(bytes = bytes)
                }
            } catch (error: Exception) {
                if (isActive && admitsCount(next, owner)) {
                    mutable.value = mutable.value.copy(readFailed = true, failure = error.message)
                }
            } finally {
                if (countOwner === owner) { countTask = null; countOwner = null }
            }
        }
        countTask = task
        mutable.value = if (changed) MonitorSettingsCacheState() else
            mutable.value.copy(bytes = null, readFailed = false,
                failure = if (mutable.value.clearFailed) mutable.value.failure else null)
        oldCount?.cancel(); oldClear?.cancel()
        if (countOwner === owner && source === next && sourceRevision == revision) task.start()
        else task.cancel()
    }
    public fun requestClear(): Unit {
        val captured = source ?: return
        if (mutable.value.clearing || !admits(captured)) return
        confirmation = captured; mutable.value = mutable.value.copy(confirmationPresented = true)
    }
    public fun cancelConfirmation(): Unit {
        confirmation = null; mutable.value = mutable.value.copy(confirmationPresented = false)
    }
    public fun clear(): Unit {
        val captured = confirmation
        cancelConfirmation()
        if (mutable.value.clearing || captured == null || !admits(captured)) return
        val owner = Any(); clearOwner = owner
        val task = scope.launch(start = CoroutineStart.LAZY) {
            if (!isActive || !admitsClear(captured, owner)) { finish(owner); return@launch }
            var succeeded = false
            try { captured.clear(); succeeded = true }
            catch (error: Exception) {
                if (coroutineContext.isActive && admitsClear(captured, owner)) {
                    mutable.value = mutable.value.copy(clearFailed = true, failure = error.message)
                }
            }
            val completionSource = source
            val completionRevision = sourceRevision
            val stillOwned = isActive && admitsClear(captured, owner)
            if (succeeded && stillOwned) {
                val summary = captured.clearSummary?.invoke()
                if (clearOwner === owner && source === completionSource && sourceRevision == completionRevision) {
                    mutable.value = mutable.value.copy(clearSummary = summary)
                }
            }
            finish(owner)
            if (stillOwned && isActive && source === completionSource &&
                sourceRevision == completionRevision && clearOwner == null && admits(captured) &&
                source === completionSource && sourceRevision == completionRevision) {
                source?.let { refresh(it) }
            }
        }
        clearTask = task
        mutable.value = mutable.value.copy(clearing = true, clearFailed = false, failure = null, clearSummary = null)
        if (clearOwner === owner) task.start() else task.cancel()
    }
    public fun dismissError(): Unit { mutable.value = mutable.value.copy(clearFailed = false, readFailed = false, failure = null) }
    public fun retire(): Unit {
        val oldCount = countTask; val oldClear = clearTask
        countOwner = null; clearOwner = null; source = null; confirmation = null
        sourceRevision += 1
        countTask = null; clearTask = null
        mutable.value = MonitorSettingsCacheState()
        oldCount?.cancel(); oldClear?.cancel()
    }
    private fun finish(owner: Any): Unit {
        if (clearOwner !== owner) return
        clearTask = null; clearOwner = null
        mutable.value = mutable.value.copy(clearing = false)
    }
    private fun admits(captured: MonitorSettingsCacheSource): Boolean {
        val current = source ?: return false
        val revision = sourceRevision
        if (current.identity != captured.identity) return false
        val admitted = captured.isCurrent()
        return admitted && source === current && sourceRevision == revision
    }
    private fun admitsCount(captured: MonitorSettingsCacheSource, owner: Any): Boolean {
        if (countOwner !== owner) return false
        val admitted = admits(captured)
        return admitted && countOwner === owner
    }
    private fun admitsClear(captured: MonitorSettingsCacheSource, owner: Any): Boolean {
        if (clearOwner !== owner) return false
        val admitted = admits(captured)
        return admitted && clearOwner === owner
    }
}
