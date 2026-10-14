package com.opencapture.opencine.media

/** Identity of measured counters, separate from the logical incident session. */
public data class FeedIncidentCounterEpoch(val decoderGeneration: Long? = null,
    val socketGeneration: Long? = null, val processedPresentation: Boolean? = null)

/** Cumulative counts in one producer lifetime. An unavailable stage has no count. */
public data class FeedIncidentStageCounts(
    val packet: Long? = null, val accessUnit: Long? = null, val decodeSubmit: Long? = null,
    val decodeAccept: Long? = null, val decodedOutput: Long? = null, val assistOutput: Long? = null,
    val present: Long? = null, val ack: Long? = null,
)

/** Optional observations beside the original numeric compatibility projection. */
public data class FeedIncidentRateObservation(
    val packetHz: Double? = null, val accessUnitHz: Double? = null, val decodeSubmitHz: Double? = null,
    val decodeAcceptHz: Double? = null, val decodedOutputHz: Double? = null, val assistOutputHz: Double? = null,
    val presentHz: Double? = null, val ackHz: Double? = null,
) {
    public fun rates(): FeedIncidentRates = FeedIncidentRates(packetHz ?: 0.0, accessUnitHz ?: 0.0,
        decodeSubmitHz ?: 0.0, decodeAcceptHz ?: 0.0, decodedOutputHz ?: 0.0, assistOutputHz ?: 0.0,
        presentHz ?: 0.0, ackHz ?: 0.0, observed = this)
}

/** Use under the producer's existing serialization; reset when its counter owner changes. */
public class FeedIncidentRateSampler {
    private var previousAt: Double? = null
    private var previousCounts: FeedIncidentStageCounts? = null
    private var epoch: FeedIncidentCounterEpoch? = null
    public fun reset() { previousAt = null; previousCounts = null; epoch = null }
    public fun sample(now: Double, counts: FeedIncidentStageCounts,
        epoch: FeedIncidentCounterEpoch? = null): FeedIncidentRates {
        if (this.epoch != epoch) { previousAt = null; previousCounts = null; this.epoch = epoch }
        if (!now.isFinite() || now < 0.0) return FeedIncidentRateObservation().rates()
        val at = previousAt
        val prior = previousCounts
        if (at != null && now <= at) return FeedIncidentRateObservation().rates()
        previousAt = now
        previousCounts = counts
        if (at == null || prior == null) return FeedIncidentRateObservation().rates()
        val elapsed = now - at
        fun rate(current: Long?, old: Long?): Double? {
            if (current == null || old == null || old < 0 || current < old) return null
            return ((current - old).toDouble() / elapsed).takeIf { it.isFinite() }
        }
        return FeedIncidentRateObservation(rate(counts.packet, prior.packet),
            rate(counts.accessUnit, prior.accessUnit), rate(counts.decodeSubmit, prior.decodeSubmit),
            rate(counts.decodeAccept, prior.decodeAccept), rate(counts.decodedOutput, prior.decodedOutput),
            rate(counts.assistOutput, prior.assistOutput), rate(counts.present, prior.present),
            rate(counts.ack, prior.ack)).rates()
    }
    public companion object {
        /** Both readings must use the same clock domain. Future and invalid stamps are unknown. */
        public fun age(stamp: Double?, now: Double): Double? = stamp?.takeIf {
            it.isFinite() && now.isFinite() && it <= now
        }?.let { (now - it).takeIf { age -> age.isFinite() } }
        public fun ageMilliseconds(stamp: Long?, now: Long): Double? = stamp?.takeIf {
            it >= 0 && now >= it
        }?.let { (now - it) / 1_000.0 }
    }
}
