package com.opencapture.opencine.dji

import com.opencapture.opencine.core.MonotonicInstant
import com.opencapture.opencine.core.SessionCloseReason
import kotlinx.coroutines.CoroutineScope
import java.util.UUID

/**
 * One native connection's common-control lifetime. Operator reconnects replace it; datalink
 * recovery keeps it. Native teardown is admitted only for the current binding. No wire calls.
 * Confined to the native session owner, like [DjiCameraSessionAdapter].
 */
public class DjiControlSessionBinding(
    private val port: PocketControlPort,
    private val scope: CoroutineScope,
    private val onClose: (SessionCloseReason) -> Unit,
    private val clock: () -> MonotonicInstant = { MonotonicInstant.now() },
) {
    private var owner: UUID? = null

    /** Notifications must not create a session. */
    public var cached: DjiCameraSessionAdapter? = null
        private set

    /** The connection's one adapter. A retired connection's adapter is never reused. */
    public val session: DjiCameraSessionAdapter
        get() {
            cached?.let { return it }
            val nextOwner = UUID.randomUUID()
            owner = nextOwner
            return DjiCameraSessionAdapter(port, scope, clock = clock, onClose = { reason ->
                close(nextOwner, reason)
            }).also { cached = it }
        }

    /** Before a new operator connection changes the native target. Recovery keeps its adapter. */
    public fun beginConnection(): Unit = retire(SessionCloseReason.REPLACED)

    /** Native teardown or borrowed return owns cleanup; do not invoke it again, even reentrantly. */
    public fun retire(reason: SessionCloseReason) {
        val previous = cached
        owner = null
        cached = null
        previous?.closeNow(reason)
    }

    private fun close(expectedOwner: UUID, reason: SessionCloseReason) {
        if (owner != expectedOwner) return
        owner = null
        cached = null
        onClose(reason)
    }
}
