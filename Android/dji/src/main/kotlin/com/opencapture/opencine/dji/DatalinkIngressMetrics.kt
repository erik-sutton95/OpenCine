package com.opencapture.opencine.dji

import com.opencapture.opencine.media.FeedIncidentIngress
import com.opencapture.opencine.media.FeedIngressMetrics
import java.util.concurrent.atomic.AtomicLong

/** Serializes diagnostics with the existing native endpoint epoch, without holding an IO lock. */
internal class DatalinkIngressMetrics(private val nativeFeedbackEpoch: AtomicLong) {
    private val lock = Any()
    private var metrics: FeedIngressMetrics? = null

    fun retireGeneration(): Long = synchronized(lock) {
        val generation = nativeFeedbackEpoch.incrementAndGet()
        metrics = generation.takeIf { it in 0..Int.MAX_VALUE.toLong() }?.let {
            FeedIngressMetrics().apply { reset(it.toInt()) }
        }
        generation
    }

    fun record(event: FeedIngressMetrics.Event, at: Double, generation: Long): Boolean = synchronized(lock) {
        if (generation != nativeFeedbackEpoch.get() || generation !in 0..Int.MAX_VALUE.toLong()) {
            false
        } else {
            metrics?.record(event, at, generation.toInt()) ?: false
        }
    }

    fun snapshot(now: Double, videoGateOpen: Boolean): FeedIncidentIngress? = synchronized(lock) {
        metrics?.snapshot(now, videoGateOpen)
    }
}
