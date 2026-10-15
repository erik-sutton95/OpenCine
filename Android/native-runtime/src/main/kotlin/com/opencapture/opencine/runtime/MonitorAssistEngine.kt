package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.media.ScopeClipSnapshot
import com.opencapture.opencine.media.ScopeSampler
import com.opencapture.opencine.media.ScopeSamples
import com.opencapture.opencine.media.ScopeTapPolicy
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive

/** Facts supplied by the picture source, independently of the app or transport. */
public data class MonitorAssistScopeConfiguration(
    public val transfer: MonitorTransfer,
    public val ceiling: ScopeClipSnapshot,
    public val defaultScopeLook: MonitorLUTCube? = null,
)

/** Native adapters lend one newly sampled frame. Null means unchanged; empty samples mean unreadable. */
public fun interface MonitorAssistScopeSource {
    public suspend fun read(includePoints: Boolean): ScopeSamples?
}

/** Shared still-picture scope cadence, history and source publication ownership. */
public class MonitorAssistEngine(
    private val nowNanos: () -> Long = System::nanoTime,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    /** Runs on the caller's native worker until cancellation or source replacement. */
    public suspend fun run(
        source: MonitorAssistScopeSource,
        configuration: MonitorAssistScopeConfiguration,
        policy: ScopeTapPolicy,
        bus: ScopeSampleBus,
        thermalMultiplier: Double = 1.0,
        role: ScopeSampleBus.Role = ScopeSampleBus.Role.LIVE,
    ) {
        if (policy.activeScopeCount == 0) return
        val lease = bus.openSource(role)
        var previous = ScopeAssistBundle.EMPTY
        try {
            while (currentCoroutineContext().isActive && bus.isCurrent(lease)) {
                val start = nowNanos()
                val samples = source.read(policy.includePoints || policy.includeVectorPoints)
                currentCoroutineContext().ensureActive()
                if (!bus.isCurrent(lease)) return
                if (samples != null) {
                    val next = bundle(samples, configuration, policy, previous)
                    if (!bus.publish(lease, next)) return
                    previous = next
                }
                // A slow decode cannot accumulate catch-up work. At most one frame is admitted per tick.
                val remaining = policy.minIntervalNs(thermalMultiplier) - (nowNanos() - start)
                pause((remaining / 1_000_000L).coerceAtLeast(1L))
                currentCoroutineContext().ensureActive()
            }
        } finally {
            bus.closeSource(lease)
        }
    }

    public companion object {
        /** Shared derivation for native live and item-owned playback consumers. */
        public fun bundle(
            samples: ScopeSamples,
            configuration: MonitorAssistScopeConfiguration,
            policy: ScopeTapPolicy,
            previous: ScopeAssistBundle = ScopeAssistBundle.EMPTY,
        ): ScopeAssistBundle {
            val readable = samples.histogramLuma.any { it > 0 }
            val history = if (readable) previous else ScopeAssistBundle.EMPTY
            val look = policy.vectorLut ?: configuration.defaultScopeLook
            return ScopeSampler.bundle(
                samples, configuration.transfer, includePoints = policy.includePoints,
                includeVectorPoints = policy.includeVectorPoints && look != null,
                look = look,
                trafficThreshold = policy.trafficThreshold, previous = history,
                ceiling = configuration.ceiling, iso = policy.iso,
            ).copy(revision = previous.revision + 1)
        }
    }
}
