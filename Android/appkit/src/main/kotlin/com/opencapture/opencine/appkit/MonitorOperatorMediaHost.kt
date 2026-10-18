package com.opencapture.opencine.appkit

import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The item the one media host presents over its catalog, and the gallery admission it holds. */
public class MonitorOperatorMediaPresented<P> internal constructor(
    public val request: MonitorMediaGalleryOpen<P>,
    public val admission: MonitorMediaLibraryActionToken,
)

/**
 * Presentation lifetime for the one media host: a player or photo viewer opens only from the
 * current gallery and closes when that gallery's lifetime ends (camera change, rebind, close).
 * A presentation that relists its own gallery (a deletion that retires the browse) keeps itself
 * across that relist with [retaining] and returns with the successor admission through [readmit].
 */
public class MonitorOperatorMediaHost<P>(public val library: MonitorMediaLibraryModel<P>) {
    private val mutable = MutableStateFlow<MonitorOperatorMediaPresented<P>?>(null)
    public val presented: StateFlow<MonitorOperatorMediaPresented<P>?> = mutable.asStateFlow()
    private val retained = mutableMapOf<UUID, Int>()
    private val released = MutableStateFlow(0)
    /** Changes when a retention ends; the host re-checks the presentation on the next frame, after
     * the presentation's own completion callback had its chance to [readmit]. */
    public val retentionReleases: StateFlow<Int> = released.asStateFlow()

    public fun open(request: MonitorMediaGalleryOpen<P>): Boolean {
        if (!library.isCurrent(request.admission)) return false
        mutable.value = MonitorOperatorMediaPresented(request, request.admission)
        return true
    }
    public fun isCurrent(request: UUID): Boolean {
        val current = mutable.value ?: return false
        return current.request.id == request && library.isCurrent(current.admission)
    }
    public fun close(request: UUID) {
        if (mutable.value?.request?.id == request) mutable.value = null
    }
    /** The successor admission of the presentation's own relist; the request identity is kept. */
    public fun readmit(request: UUID, admission: MonitorMediaLibraryActionToken): Boolean {
        val current = mutable.value ?: return false
        if (current.request.id != request || !library.isCurrent(admission)) return false
        mutable.value = MonitorOperatorMediaPresented(current.request, admission)
        return true
    }
    public suspend fun <T> retaining(request: UUID, block: suspend () -> T): T {
        retained[request] = (retained[request] ?: 0) + 1
        try { return block() } finally {
            val count = (retained[request] ?: 1) - 1
            if (count > 0) retained[request] = count else retained.remove(request)
            released.value += 1
        }
    }
    /** Call on every gallery lifetime change and retention release. */
    public fun sourceChanged() {
        val current = mutable.value ?: return
        if (current.request.id in retained || library.isCurrent(current.admission)) return
        mutable.value = null
    }
}
