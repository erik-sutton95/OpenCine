package com.opencapture.opencine.media

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DiagnosticJournalTest {
    @Test
    fun appendNeverWaitsOnPersistAndDropsWhenTheWriterIsStuck() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val persisted = AtomicInteger(0)
        val journal = DiagnosticJournal(cap = 8, queueCap = 2)
        journal.startWriter { batch ->
            persisted.addAndGet(batch.size)
            entered.countDown()
            release.await(2, TimeUnit.SECONDS)
        }
        journal.append("one")
        assertTrue(entered.await(1, TimeUnit.SECONDS), "writer must take the first line off-thread")
        repeat(8) { journal.append("burst-$it") }
        val snapshot = journal.snapshot()
        assertEquals(8, snapshot.size)
        assertTrue(journal.droppedCount() >= 1, "a full persist queue must drop, not block")
        release.countDown()
        journal.shutdownWriter()
    }

    @Test
    fun ringKeepsTheNewestLinesWithoutAWriter() {
        val journal = DiagnosticJournal(cap = 3)
        journal.append("a")
        journal.append("b")
        journal.append("c")
        journal.append("d")
        assertEquals(listOf("b", "c", "d"), journal.snapshot())
        assertEquals(0, journal.droppedCount())
    }

    @Test
    fun restoredLinesSitBeforeNewerOnesAndAreNeverPersistedAgain() {
        val persisted = mutableListOf<String>()
        val journal = DiagnosticJournal(cap = 3)
        journal.append("live")
        journal.restore(listOf("old-1", "old-2", "old-3"))
        assertEquals(listOf("old-2", "old-3", "live"), journal.snapshot())
        assertEquals(0, journal.pendingCount())
        journal.startWriter { batch -> synchronized(persisted) { persisted += batch } }
        journal.restore(listOf("older"))
        assertEquals(0, journal.pendingCount())
        // Restored lines are the oldest, so a full ring evicts them first.
        assertEquals(listOf("old-2", "old-3", "live"), journal.snapshot())
        journal.shutdownWriter()
        assertTrue(synchronized(persisted) { persisted.isEmpty() })
    }
}
