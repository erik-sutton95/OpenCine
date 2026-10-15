package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertFailsWith

class MonitorLutArchiveBudgetTest {
    @Test fun exactTotalAcceptsMultipleChunksAndAnEmptyChunk() {
        val budget = MonitorLutArchiveBudget(9)
        budget.consume(4)
        budget.consume(0)
        budget.consume(5)
        assertFailsWith<MonitorLutArchiveLimitExceeded> { budget.consume(1) }
    }

    @Test fun rejectedChunkDoesNotConsumeTheRemainingBudget() {
        val budget = MonitorLutArchiveBudget(9)
        budget.consume(4)
        assertFailsWith<MonitorLutArchiveLimitExceeded> { budget.consume(6) }
        budget.consume(5)
    }

    @Test fun negativeCountsCannotIncreaseAvailableBytes() {
        val budget = MonitorLutArchiveBudget(0)
        assertFailsWith<MonitorLutArchiveLimitExceeded> { budget.consume(-1) }
        assertFailsWith<MonitorLutArchiveLimitExceeded> { budget.consume(1) }
        assertFailsWith<IllegalArgumentException> { MonitorLutArchiveBudget(-1) }
    }

    @Test fun totalCounterDoesNotOverflowAtTheIntegerBoundary() {
        val budget = MonitorLutArchiveBudget(Int.MAX_VALUE.toLong() + 5)
        budget.consume(Int.MAX_VALUE)
        assertFailsWith<MonitorLutArchiveLimitExceeded> { budget.consume(6) }
        budget.consume(5)
    }
}
