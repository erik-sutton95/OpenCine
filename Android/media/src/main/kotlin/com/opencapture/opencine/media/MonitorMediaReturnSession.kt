package com.opencapture.opencine.media

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** One pending return claim on the supplied owner dispatcher. Integration recovery/exit policy
 * remains in the captured operation; this owner never infers a camera command. */
public class MonitorMediaReturnSession(private val scope: CoroutineScope) {
    public var generation: Long = 0
        private set
    public var task: Deferred<Unit>? = null
        private set
    public val pending: Boolean get() = task != null

    public fun cancel() {
        generation += 1
        val previous = task
        task = null
        previous?.cancel()
    }

    public fun start(ifCurrent: (Long) -> Boolean, operation: suspend (Long) -> Unit,
        completed: (Long) -> Unit = {}): Long {
        cancel()
        val token = generation
        if (!ifCurrent(token) || generation != token) return token
        val next = scope.async(start = CoroutineStart.LAZY) {
            try {
                currentCoroutineContext().ensureActive()
                if (generation != token || !ifCurrent(token) || generation != token) return@async
                operation(token)
                currentCoroutineContext().ensureActive()
                if (generation != token) return@async
                task = null
                if (ifCurrent(token) && generation == token) completed(token)
            } finally { if (generation == token) task = null }
        }
        next.invokeOnCompletion { if (generation == token && task === next) task = null }
        if (generation == token) {
            task = next
            next.start()
        } else next.cancel()
        return token
    }
}
