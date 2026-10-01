package com.opencapture.opencine.multicam

import com.opencapture.opencine.core.MonitorEntryID
import com.opencapture.opencine.core.MonotonicInstant
import kotlin.time.Duration

/**
 * One entry's bounded recovery budget. The integration owns the ladder (what a recovery step
 * is, how a link or picture is repaired); the engine only counts attempts so a failing entry
 * stops retrying on its own and never takes healthy peers with it. A sustained healthy period
 * restores the budget. Generalized from a per-tile rejoin budget (two rejoins, reset after 30 s
 * healthy) without its transport assumptions. Mutable and unsynchronized: confine it to its owner.
 */
public class RecoveryBudget(public val limit: Int, public val resetAfterHealthy: Duration) {
    public sealed interface Status {
        public data object Healthy : Status
        public data class Recovering(public val attempt: Int, public val of: Int) : Status

        /** Out of attempts: waits for an operator action (retry or remove). */
        public data object Exhausted : Status
    }

    public var used: Int = 0
        private set
    public var exhausted: Boolean = false
        private set
    private var healthySince: MonotonicInstant? = null

    public val status: Status
        get() = when {
            exhausted -> Status.Exhausted
            healthySince == null && used > 0 -> Status.Recovering(used, limit)
            else -> Status.Healthy
        }

    /** Reports the entry's health as the integration judges it. */
    public fun observe(healthy: Boolean, now: MonotonicInstant) {
        if (exhausted) return
        if (!healthy) {
            healthySince = null
            return
        }
        val since = healthySince ?: now
        healthySince = since
        if (now - since >= resetAfterHealthy) used = 0
    }

    /**
     * Whether the integration may start another recovery attempt. Returns `false` and exhausts
     * the budget once the limit is used.
     */
    public fun beginAttempt(): Boolean {
        if (exhausted || used >= limit) {
            exhausted = true
            return false
        }
        used += 1
        healthySince = null
        return true
    }

    /** The operator's retry: a fresh budget. */
    public fun reset() {
        used = 0
        exhausted = false
        healthySince = null
    }
}

/** Recovery budgets of every entry. Each entry's budget is independent. */
public class RecoveryLedger(public val limit: Int, public val resetAfterHealthy: Duration) {
    private val active = LinkedHashMap<MonitorEntryID, RecoveryBudget>()

    public val budgets: Map<MonitorEntryID, RecoveryBudget> get() = active.toMap()

    /** The entry's budget, created fresh on first use; mutate it in place. */
    public operator fun get(entry: MonitorEntryID): RecoveryBudget =
        active.getOrPut(entry) { RecoveryBudget(limit, resetAfterHealthy) }

    /** Entries waiting for an operator action. */
    public val exhausted: List<MonitorEntryID> get() = active.filterValues { it.exhausted }.keys.toList()

    /** Drops budgets of entries that left the group. */
    public fun prune(group: MulticamGroup) {
        active.keys.retainAll { group[it] != null }
    }
}
