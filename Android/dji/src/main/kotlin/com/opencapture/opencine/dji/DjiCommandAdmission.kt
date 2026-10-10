package com.opencapture.opencine.dji

import java.util.UUID

/** Published identity of one actual endpoint. Replacement retires prior receipts; close is permanent.
 * This admission value owns no native queue, transport or scheduler. */
public class DjiCommandOwner {
    private var window: UUID = UUID.randomUUID()
    private var active: Boolean = true
    public val source: UUID @Synchronized get() = window
    @Synchronized public fun replaceSource(): Unit { window = UUID.randomUUID() }
    @Synchronized public fun retire(): Unit { active = false }
    @Synchronized internal fun admits(source: UUID): Boolean = active && source == window
}

public class DjiCommandAdmissionException : IllegalStateException("Command authority expired")

/** Explicit authority for one queued operation. The supplied predicate must be thread-safe. */
public class DjiCommandAdmission(
    public val owner: DjiCommandOwner,
    isCurrent: () -> Boolean,
) {
    private val currentPredicate: () -> Boolean = isCurrent
    public val source: UUID = owner.source
    public val isCurrent: Boolean get() {
        if (!owner.admits(source)) return false
        val accepted = runCatching(currentPredicate).getOrDefault(false)
        return owner.admits(source) && accepted
    }
    public fun admits(source: DjiCommandOwner?): Boolean = source === owner && isCurrent
    public fun require(owner: DjiCommandOwner?): Unit {
        if (!admits(owner)) throw DjiCommandAdmissionException()
    }
    public fun requireCurrent(): Unit {
        if (!isCurrent) throw DjiCommandAdmissionException()
    }
    /** Entered native work retains its original completion even if its receipt retires inside it. */
    public fun <Result> perform(operation: () -> Result): Result {
        requireCurrent()
        return operation()
    }
}
