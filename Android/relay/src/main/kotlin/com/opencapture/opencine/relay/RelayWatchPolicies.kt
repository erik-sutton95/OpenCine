package com.opencapture.opencine.relay

import java.util.UUID

/** Reservations span native encoding and transport, with one-use generation-scoped completion. */
public class RelayPreviewReservations(public val maximumInFlight: Int = 3) {
    public data class Ticket(public val generation: Long, public val sequence: Long)
    private var generation = 0L
    private var sequence = 0L
    private val outstanding = mutableSetOf<Ticket>()
    public val inFlightCount: Int @Synchronized get() = outstanding.size

    init { require(maximumInFlight > 0) }
    @Synchronized public fun reserve(): Ticket? {
        if (outstanding.size >= maximumInFlight) return null
        sequence += 1
        return Ticket(generation, sequence).also(outstanding::add)
    }
    @Synchronized public fun isCurrent(ticket: Ticket): Boolean = ticket.generation == generation && ticket in outstanding
    @Synchronized public fun complete(ticket: Ticket): Boolean = outstanding.remove(ticket)
    @Synchronized public fun invalidate(releasingOutstanding: Boolean = false): Unit {
        generation += 1
        if (releasingOutstanding) outstanding.clear()
    }
}

public data class RelayPreviewProfile(public val maximumWidth: Int, public val qualityPercent: Int) {
    init { require(maximumWidth > 0 && qualityPercent in 0..100) }
}

/** Supplied link budgets, from highest quality to lowest; an initial hint is not an observation. */
public class RelayPreviewPacingPolicy(
    profiles: List<RelayPreviewProfile>,
    roundTripThresholds: List<Double>,
    public val initialIndex: Int,
    public val initialRoundTripHint: Double? = null,
    public val previousSampleWeight: Double = 0.8,
    public val currentSampleWeight: Double = 0.2,
    public val maximumSampleSeconds: Double? = null,
    public val sampleUnitsPerSecond: Double = 1.0,
) {
    public val profiles: List<RelayPreviewProfile> = profiles.toList()
    public val roundTripThresholds: List<Double> = roundTripThresholds.toList()
    init {
        require(this.profiles.isNotEmpty() && this.roundTripThresholds.size == this.profiles.size - 1)
        require(initialIndex in this.profiles.indices)
        require(this.roundTripThresholds.all { it.isFinite() && it > 0 })
        require(this.roundTripThresholds.zipWithNext().all { (first, second) -> first < second })
        require(previousSampleWeight >= 0 && previousSampleWeight < 1)
        require(currentSampleWeight > 0 && currentSampleWeight <= 1)
        require(kotlin.math.abs(previousSampleWeight + currentSampleWeight - 1) < 1e-12)
        require(initialRoundTripHint == null || initialRoundTripHint.isFinite() && initialRoundTripHint > 0)
        require(maximumSampleSeconds == null || maximumSampleSeconds.isFinite() && maximumSampleSeconds > 0)
        require(sampleUnitsPerSecond.isFinite() && sampleUnitsPerSecond > 0)
    }
}

/** The runtime admits the captured current preview ticket before feeding acknowledgements here. */
public class RelayPreviewPacing(public val policy: RelayPreviewPacingPolicy) {
    public var profileIndex: Int = policy.initialIndex
        private set
    public var observedRoundTripSeconds: Double? = null
        private set
    private var estimate = policy.initialRoundTripHint?.times(policy.sampleUnitsPerSecond)
    public val currentProfile: RelayPreviewProfile @Synchronized get() = policy.profiles[profileIndex]

    @Synchronized public fun acknowledge(roundTripSeconds: Double): RelayPreviewProfile =
        acknowledgeInSampleUnits(roundTripSeconds * policy.sampleUnitsPerSecond)
    /** Preserve the exercised producer's floating-point unit before smoothing, including ms. */
    @Synchronized public fun acknowledgeInSampleUnits(sample: Double): RelayPreviewProfile {
        val roundTripSeconds = sample / policy.sampleUnitsPerSecond
        if (!roundTripSeconds.isFinite() || roundTripSeconds <= 0 ||
            policy.maximumSampleSeconds?.let { roundTripSeconds >= it } == true) return currentProfile
        val value = estimate?.let {
            it * policy.previousSampleWeight + sample * policy.currentSampleWeight
        } ?: sample
        estimate = value; observedRoundTripSeconds = value / policy.sampleUnitsPerSecond
        profileIndex = policy.roundTripThresholds.count { value >= it * policy.sampleUnitsPerSecond }
        return currentProfile
    }
    @Synchronized public fun timedOut(): RelayPreviewProfile {
        profileIndex = (profileIndex + 1).coerceAtMost(policy.profiles.lastIndex)
        estimate = null; observedRoundTripSeconds = null
        return currentProfile
    }
    @Synchronized public fun reset(): Unit {
        profileIndex = policy.initialIndex; estimate = policy.initialRoundTripHint?.times(policy.sampleUnitsPerSecond)
        observedRoundTripSeconds = null
    }
}

/** Freshness comes from an authoritative state receipt, not a reachable installed capability. */
public class RelayWatchFreshness(public val maximumAgeSeconds: Double) {
    private var acceptedAt: Double? = null
    init { require(maximumAgeSeconds.isFinite() && maximumAgeSeconds > 0) }
    public fun accept(now: Double): Unit { acceptedAt = now }
    public fun clear(): Unit { acceptedAt = null }
    public fun isFresh(now: Double): Boolean = acceptedAt?.let { now - it >= 0 && now - it < maximumAgeSeconds } == true
    public fun remainingSeconds(now: Double): Double? = acceptedAt?.let {
        (maximumAgeSeconds - (now - it).coerceAtLeast(0.0)).coerceAtLeast(0.0)
    }
}

public data class RelayWatchPendingCommand(public val peer: String, public val request: Long, public val source: UUID) {
    public fun matches(peer: String, request: Long, source: UUID): Boolean =
        this.peer == peer && this.request == request && this.source == source
}

public class RelayWatchFrameSequence {
    private var latestRequest = 0L
    public fun accept(request: Long): Boolean {
        if (request <= latestRequest) return false
        latestRequest = request
        return true
    }
    public fun clear(): Unit { latestRequest = 0 }
}

/** Thread-confined latest-wins work admission; callbacks run outside the reservation lock. */
public class RelayLatestPreviewPump<Value : Any>(
    maximumInFlight: Int = 1,
    private val releasingOutstandingOnInvalidate: Boolean = true,
    private val dispatch: (Dispatch<Value>) -> Unit,
    private val onDiscard: (Value) -> Unit = {},
) {
    public data class Dispatch<Value : Any>(public val value: Value, public val token: Long)
    private val reservations = RelayPreviewReservations(maximumInFlight)
    private val tickets = mutableMapOf<Long, RelayPreviewReservations.Ticket>()
    private var latest: Value? = null

    public fun offer(value: Value): Unit {
        val admitted: Dispatch<Value>?
        val discarded: Value?
        synchronized(this) {
            val ticket = reservations.reserve()
            if (ticket == null) { discarded = latest; latest = value; admitted = null }
            else { discarded = null; tickets[ticket.sequence] = ticket; admitted = Dispatch(value, ticket.sequence) }
        }
        discarded?.let(onDiscard)
        admitted?.let(dispatch)
    }
    public fun complete(token: Long): Unit {
        val admitted: Dispatch<Value>?
        synchronized(this) {
            val ticket = tickets.remove(token) ?: return
            if (!reservations.complete(ticket)) return
            val pending = latest
            latest = null
            val successor = if (pending != null) reservations.reserve() else null
            admitted = if (successor != null && pending != null) {
                tickets[successor.sequence] = successor
                Dispatch(pending, successor.sequence)
            } else null
        }
        admitted?.let(dispatch)
    }
    public fun invalidate(): Unit {
        val discarded: Value?
        synchronized(this) {
            discarded = latest; latest = null
            if (releasingOutstandingOnInvalidate) tickets.clear()
            reservations.invalidate(releasingOutstanding = releasingOutstandingOnInvalidate)
        }
        discarded?.let(onDiscard)
    }
    public fun isBusy(): Boolean = synchronized(this) { reservations.inFlightCount > 0 || latest != null }
    public fun isActive(token: Long): Boolean = synchronized(this) {
        tickets[token]?.let(reservations::isCurrent) == true
    }
}
