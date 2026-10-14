package com.opencapture.opencine.decoder

import com.opencapture.opencine.media.CodecFailureAction
import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HevcDecoderCodecFailureTest {
    /** SIMULATED native input; the real queue catch/feed bookkeeping and callback run unchanged. */
    private class Input(private val failure: HevcInputFailure? = null) : HevcInputCodec {
        var dequeues = 0
        var queued = 0
        override fun dequeueInputBuffer(waitUs: Long): Int {
            dequeues++
            if (failure != null) throw IllegalStateException("SIMULATED input failure")
            return 0
        }
        override fun getInputBuffer(index: Int) = ByteBuffer.allocate(128)
        override fun queueInputBuffer(index: Int, size: Int, ptsUs: Long, flags: Int) { queued++ }
        override fun failure(error: Exception) = failure
    }

    @Test fun reentrantQueueDiagnosticCannotRetireAReplacementCodecOrItsReferences() {
        val lock = Any()
        val old = Input(HevcInputFailure(1101, false, false))
        val successor = Input()
        var callbacks = 0
        var calledUnderLock = false
        lateinit var decoder: HevcDecoder
        decoder = HevcDecoder(lock = lock, errorJournal = {
            callbacks++
            calledUnderLock = Thread.holdsLock(lock)
            decoder.reset()
            decoder.adoptInputCodecForTest(successor)
            decoder.randomAccess.adoptDecodableReferencesForTest()
        })
        decoder.adoptInputCodecForTest(old)
        decoder.randomAccess.adoptDecodableReferencesForTest()
        val originalInput = decoder.captureInputOwnership()
        // A non-keyframe goes through the actual established feed, then fails in native queue.
        assertFalse(decoder.decode(byteArrayOf(0, 0, 0, 1, 2, 1, 1), originalInput.owner, originalInput.epoch))
        assertEquals(1, callbacks)
        assertFalse(calledUnderLock, "Host diagnostics are delivered outside the native lock")
        assertTrue(decoder.isConfigured, "A's recovery must not retire B")
        assertTrue(decoder.hasDecodableReferences, "A's failed feed must not mark B's references lost")
        assertFalse(decoder.referenceRecoveryNeeded)
        assertEquals(0, successor.dequeues, "A's bytes are never retried on B")
        assertEquals(0, successor.queued)
        assertEquals(0, decoder.decoderErrors.get(), "B retains its reset diagnostic lifetime")
    }

    @Test fun reentrantTransientQueueDiagnosticNeverRetriesOldSourceBytesOnTheReplacement() {
        val old = Input(HevcInputFailure(-2147479551, true, false))
        val successor = Input()
        var callbacks = 0
        lateinit var decoder: HevcDecoder
        decoder = HevcDecoder(errorJournal = {
            callbacks++
            decoder.reset()
            decoder.adoptInputCodecForTest(successor)
            decoder.randomAccess.adoptDecodableReferencesForTest()
        })
        decoder.adoptInputCodecForTest(old)
        decoder.randomAccess.adoptDecodableReferencesForTest()
        val source = decoder.captureInputOwnership()
        assertFalse(decoder.decode(byteArrayOf(0, 0, 0, 1, 2, 1, 1), source.owner, source.epoch))
        assertEquals(1, callbacks)
        assertEquals(2, old.dequeues, "A transient failure permits one retry on its captured codec")
        assertEquals(0, successor.dequeues, "The admitted retry belongs to A, never B")
        assertEquals(0, successor.queued)
        assertTrue(decoder.hasDecodableReferences)
    }

    @Test fun reclaimedCodecIsRebuiltAndAsksTheHostForAnIrap() {
        val decoder = HevcDecoder()
        decoder.randomAccess.adoptDecodableReferencesForTest()
        val action = decoder.onCodecFailure(errorCode = 1101, isTransient = false, isRecoverable = false)
        assertEquals(CodecFailureAction.REBUILD, action)
        // The watchdog reads known reference loss on its next tick and requests an IRAP;
        // the replacement codec holds inter frames until that IRAP arrives.
        assertTrue(decoder.referenceRecoveryNeeded)
        assertTrue(decoder.awaitingIdr)
        assertFalse(decoder.hasDecodableReferences)
        assertFalse(decoder.isConfigured)
    }

    @Test fun transientCodecFailureKeepsTheCodecAndItsReferences() {
        val decoder = HevcDecoder()
        decoder.randomAccess.adoptDecodableReferencesForTest()
        val action = decoder.onCodecFailure(errorCode = -2147479551, isTransient = true, isRecoverable = false)
        assertEquals(CodecFailureAction.RETRY, action)
        assertFalse(decoder.referenceRecoveryNeeded)
        assertFalse(decoder.awaitingIdr)
        assertTrue(decoder.hasDecodableReferences)
    }
}
