package com.opencapture.opencine.cameracontrols

import java.io.IOException

/** Actual emitted archive bytes, shared across decoder entries and fallback attempts. */
class MonitorLutArchiveBudget(
    private val maximumTotalBytes: Long = DEFAULT_MAXIMUM_TOTAL_BYTES,
) {
    private var emittedBytes = 0L

    init { require(maximumTotalBytes >= 0) }

    /** Call before retaining each decoded chunk. Advertised archive sizes never advance this budget. */
    fun consume(byteCount: Int) {
        if (byteCount < 0 || byteCount.toLong() > maximumTotalBytes - emittedBytes) {
            throw MonitorLutArchiveLimitExceeded()
        }
        emittedBytes += byteCount
    }

    companion object {
        /** Same cumulative import limit as the Swift categorized store. */
        const val DEFAULT_MAXIMUM_TOTAL_BYTES: Long = 512L * 1024 * 1024
    }
}

/** A decoder must propagate this failure instead of skipping an entry or retrying without a bound. */
class MonitorLutArchiveLimitExceeded : IOException("The LUT archive exceeds the import limits.")
