package com.opencapture.opencine.dji

import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

// SIMULATED: controlled admission callbacks and native entry, without a camera or socket.
class DjiCommandPredicateReentryTest {
    @Test fun predicateReplacementCannotEnterCapturedNativeOperation() {
        val owner = DjiCommandOwner(); val calls = AtomicInteger()
        val admission = DjiCommandAdmission(owner) {
            calls.incrementAndGet(); owner.replaceSource(); true
        }
        var writes = 0
        assertFailsWith<DjiCommandAdmissionException> { admission.perform { writes++ } }
        assertEquals(0, writes); assertEquals(1, calls.get())
        val successor = DjiCommandAdmission(owner) { true }
        assertNotEquals(admission.source, successor.source)
        assertEquals("successor", successor.perform { "successor" })
        assertFalse(admission.isCurrent); assertEquals(1, calls.get())
    }

    @Test fun predicateRetirementCannotEnterCapturedNativeOperation() {
        val owner = DjiCommandOwner(); val calls = AtomicInteger()
        val admission = DjiCommandAdmission(owner) {
            calls.incrementAndGet(); owner.retire(); true
        }
        var writes = 0
        assertFailsWith<DjiCommandAdmissionException> { admission.perform { writes++ } }
        assertEquals(0, writes); assertEquals(1, calls.get())
        owner.replaceSource()
        assertFalse(DjiCommandAdmission(owner) { true }.isCurrent)
    }

    @Test fun falseReentrantPredicateLeavesSuccessorAdmitted() {
        val owner = DjiCommandOwner(); val calls = AtomicInteger()
        val admission = DjiCommandAdmission(owner) {
            calls.incrementAndGet(); owner.replaceSource(); false
        }
        var writes = 0
        assertFailsWith<DjiCommandAdmissionException> { admission.perform { writes++ } }
        assertEquals(0, writes); assertEquals(1, calls.get())
        val successor = DjiCommandAdmission(owner) { true }
        assertEquals("current", successor.perform { writes++; "current" })
        assertEquals(1, writes); assertTrue(successor.isCurrent)
    }

    @Test fun currentPredicateRunsOnceAtNativeEntry() {
        val owner = DjiCommandOwner(); val calls = AtomicInteger()
        val admission = DjiCommandAdmission(owner) { calls.incrementAndGet(); true }
        var writes = 0
        assertEquals("entered", admission.perform { writes++; "entered" })
        assertEquals(1, writes); assertEquals(1, calls.get())
    }

    @Test fun enteredOperationKeepsItsOriginalCompletion() {
        val owner = DjiCommandOwner(); val calls = AtomicInteger()
        val admission = DjiCommandAdmission(owner) { calls.incrementAndGet(); true }
        var writes = 0
        val result = admission.perform {
            writes++; owner.retire(); owner.replaceSource(); "original completion"
        }
        assertEquals("original completion", result)
        assertEquals(1, writes); assertEquals(1, calls.get())
        assertFalse(admission.isCurrent); assertEquals(1, calls.get())
    }
}
