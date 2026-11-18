package com.opencapture.opencine.appkit

import com.opencapture.opencine.core.MultiviewRepairResult
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** The coordinator's deadline on a member link's repair. Swift twin: `MultiviewRepairRaceTests`. */
class MultiviewRepairRaceTest {
    @Test
    fun aRepairEndsWithItsOwnResultBeforeItsDeadline() = runTest {
        val result = MultiviewRepairResult.race(60.seconds, backgroundScope) {
            MultiviewRepairResult.WaitForOperator("Taken over")
        }
        assertEquals(MultiviewRepairResult.WaitForOperator("Taken over"), result)
    }

    @Test
    fun aRepairStillRunningAtItsDeadlineIsCancelledAndEndsAsDone() = runTest {
        val ended = CompletableDeferred<Boolean>()
        val result = MultiviewRepairResult.race(60.seconds, backgroundScope) {
            try {
                awaitCancellation()
            } finally {
                ended.complete(true)
            }
        }
        assertEquals(MultiviewRepairResult.Done, result, "A repair past its deadline asks for nothing")
        assertTrue(ended.await(), "The repair was cancelled at its deadline")
    }
}
