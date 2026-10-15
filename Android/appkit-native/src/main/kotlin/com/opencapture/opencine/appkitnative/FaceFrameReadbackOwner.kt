package com.opencapture.opencine.appkitnative

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.StreamGeneration

/** The integration's current connection, independent of a saved camera or Compose identity. */
public data class MonitorFaceReadbackEpoch(
    public val session: CameraSessionID,
    public val control: ControlEpoch,
    public val stream: StreamGeneration? = null,
)

/**
 * One bitmap readback slot on the host's serial Main thread. Retirement refuses delivery; it does
 * not free pixels while the native copy may still write them. Only completion frees that slot.
 */
internal class FaceFrameReadbackOwner<S : Any>(
    private val currentSource: () -> S,
    private val pictureIdentity: (S) -> Any,
    private val readbackEpoch: (S) -> MonitorFaceReadbackEpoch?,
) {
    class Lifetime internal constructor()

    class Request<S : Any> internal constructor(
        val source: S,
        internal val picture: Any,
        internal val epoch: MonitorFaceReadbackEpoch,
        internal val lifetime: Lifetime,
        internal val isPumpActive: () -> Boolean,
    ) {
        internal var completed = false
    }

    private var lifetime: Lifetime? = null
    private var pending: Request<S>? = null
    private var closed = false

    fun activate(): Lifetime? {
        if (closed) return null
        return Lifetime().also { lifetime = it }
    }

    fun retire(owned: Lifetime) {
        if (lifetime === owned) lifetime = null
    }

    fun close() {
        closed = true
        lifetime = null
    }

    fun begin(isPumpActive: () -> Boolean): Request<S>? {
        val owned = lifetime ?: return null
        if (closed || pending != null || !isPumpActive()) return null
        val source = currentSource()
        val epoch = readbackEpoch(source) ?: return null
        return Request(source, pictureIdentity(source), epoch, owned, isPumpActive).also { pending = it }
    }

    /** Before a native copy starts, a null bitmap or invalid view owns no pixels. */
    fun abandon(request: Request<S>) {
        if (pending !== request || request.completed) return
        request.completed = true
        pending = null
    }

    /**
     * Called once native copying has finished, or when requesting it synchronously failed.
     * [construct] releases the raw pixels when it returns null or throws; a returned frame owns them.
     * [discard] releases an unsubmitted frame. [consume] takes ownership on entry.
     */
    fun <F : Any> complete(
        request: Request<S>,
        copied: Boolean,
        release: () -> Unit,
        construct: (S, () -> Unit) -> F?,
        discard: (S, F) -> Unit,
        consume: (S, F) -> Unit,
    ) {
        if (pending !== request || request.completed) return
        request.completed = true
        try {
            if (!copied || !isCurrent(request)) {
                release()
                return
            }
            val frame = construct(request.source, release) ?: return
            // A factory is external code: it can synchronously replace or retire the source.
            if (!isCurrent(request)) {
                discard(request.source, frame)
                return
            }
            consume(request.source, frame)
        } finally {
            if (pending === request) pending = null
        }
    }

    private fun isCurrent(request: Request<S>): Boolean {
        if (closed || lifetime !== request.lifetime || !request.isPumpActive()) return false
        val current = currentSource()
        return current === request.source && pictureIdentity(current) == request.picture &&
            readbackEpoch(current) == request.epoch
    }
}
