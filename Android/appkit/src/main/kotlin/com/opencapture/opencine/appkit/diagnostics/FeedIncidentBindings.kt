package com.opencapture.opencine.appkit.diagnostics

import com.opencapture.opencine.media.FeedIncidentSource
import com.opencapture.opencine.media.FeedIncidentSink
import com.opencapture.opencine.media.FeedIncidentSessionContext
import com.opencapture.opencine.media.FeedIncidentSnapshot
import com.opencapture.opencine.media.FeedIncidentBreadcrumb
import com.opencapture.opencine.media.FeedRepairRecord
import com.opencapture.opencine.media.FeedIncidentTestSource

/** Compatibility ownership for injected legacy sinks. Actual runtime sources also fence their writer. */
public class FeedIncidentBindings(
    private val clock: () -> Double = { android.os.SystemClock.elapsedRealtime() / 1_000.0 },
) {
    private val gate = Any()
    private var current: FeedIncidentSource? = null
    private var owner: Any? = null

    public fun sink(owner: Any, sink: FeedIncidentSink): FeedIncidentSink = object : FeedIncidentSink {
        private var legacy: FeedIncidentSource? = null
        override fun beginSession(context: FeedIncidentSessionContext) { legacy = beginBoundSession(context) }
        override fun beginBoundSession(context: FeedIncidentSessionContext): FeedIncidentSource = synchronized(gate) {
            current?.endSession(clock())
            val captured = sink.beginBoundSession(context)
            lateinit var bound: FeedIncidentSource
            bound = GuardedSource(captured, gate,
                current = { this@FeedIncidentBindings.owner === owner && current === bound },
                ended = { current = null; this@FeedIncidentBindings.owner = null })
            this@FeedIncidentBindings.owner = owner
            current = bound
            bound
        }
        override val isCurrent: Boolean get() = legacy?.isCurrent == true
        override fun endSession(nowSeconds: Double) { legacy?.endSession(nowSeconds); legacy = null }
        override fun ingestSnapshot(snapshot: FeedIncidentSnapshot) { legacy?.ingestSnapshot(snapshot) }
        override fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb) { legacy?.recordBreadcrumb(breadcrumb) }
        override fun recordRepair(repair: FeedRepairRecord) { legacy?.recordRepair(repair) }
        override fun noteDecoderGeneration(generation: Int) { legacy?.noteDecoderGeneration(generation) }
        override fun noteSocketGeneration(generation: Int) { legacy?.noteSocketGeneration(generation) }
        override fun noteExhausted(nowSeconds: Double) { legacy?.noteExhausted(nowSeconds) }
        override fun noteUnexpectedDisconnect(nowSeconds: Double) { legacy?.noteUnexpectedDisconnect(nowSeconds) }
        override fun noteTestSource(source: FeedIncidentTestSource) { legacy?.noteTestSource(source) }
    }

    public companion object {
        /** The host supplies a read-only identity check; all incident submission fencing lives here. */
        public fun bind(source: FeedIncidentSource, ownerIsCurrent: () -> Boolean): FeedIncidentSource =
            GuardedSource(source, Any(), ownerIsCurrent, {})
    }

    private class GuardedSource(
        private val source: FeedIncidentSource, private val gate: Any,
        private val current: () -> Boolean, private val ended: () -> Unit,
    ) : FeedIncidentSource {
        private var closed = false
        override val isCurrent: Boolean get() = synchronized(gate) { !closed && current() && source.isCurrent }
        private fun submit(work: (FeedIncidentSource) -> Unit) = synchronized(gate) {
            if (isCurrent) work(source)
        }
        override fun endSession(nowSeconds: Double) = synchronized(gate) {
            if (!closed) {
                closed = true
                // A captured runtime source fences its own session during disposal. A legacy
                // sink may now own a successor, so only its current host owner may end it.
                if ((current() && source.isCurrent) || source is FeedIncidentSessionSource) {
                    source.endSession(nowSeconds)
                }
                ended()
            }
        }
        override fun ingestSnapshot(snapshot: FeedIncidentSnapshot) = submit { it.ingestSnapshot(snapshot) }
        override fun recordBreadcrumb(breadcrumb: FeedIncidentBreadcrumb) = submit { it.recordBreadcrumb(breadcrumb) }
        override fun recordRepair(repair: FeedRepairRecord) = submit { it.recordRepair(repair) }
        override fun noteDecoderGeneration(generation: Int) = submit { it.noteDecoderGeneration(generation) }
        override fun noteSocketGeneration(generation: Int) = submit { it.noteSocketGeneration(generation) }
        override fun noteExhausted(nowSeconds: Double) = submit { it.noteExhausted(nowSeconds) }
        override fun noteUnexpectedDisconnect(nowSeconds: Double) = submit { it.noteUnexpectedDisconnect(nowSeconds) }
        override fun noteTestSource(source: FeedIncidentTestSource) = submit { it.noteTestSource(source) }
    }
}
