package com.opencapture.opencine.decoder

import com.opencapture.opencine.media.DecoderErrorCall
import com.opencapture.opencine.media.FeedDecoderErrorOrigin
import java.nio.ByteBuffer
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * PA-1V: an IllegalArgumentException from the decoder rode a disconnect incident with nothing
 * saying which MediaCodec call raised it. SIMULATED native input; the real queue path records it.
 */
class HevcDecoderErrorCallTest {
    private class Input(private val failing: DecoderErrorCall) : HevcInputCodec {
        override fun dequeueInputBuffer(waitUs: Long): Int {
            if (failing == DecoderErrorCall.DEQUEUE_INPUT) throw IllegalStateException("SIMULATED")
            return 0
        }
        override fun getInputBuffer(index: Int): ByteBuffer? {
            if (failing == DecoderErrorCall.GET_INPUT_BUFFER) throw IllegalArgumentException("SIMULATED")
            // Too small for the access unit, so filling it overflows.
            return ByteBuffer.allocate(if (failing == DecoderErrorCall.FILL_INPUT) 2 else 128)
        }
        override fun queueInputBuffer(index: Int, size: Int, ptsUs: Long, flags: Int) {
            if (failing == DecoderErrorCall.QUEUE_INPUT) throw IllegalArgumentException("SIMULATED")
        }
        override fun failure(error: Exception): HevcInputFailure? = null
    }

    private fun failingCall(failing: DecoderErrorCall): Pair<String?, String?> {
        val decoder = HevcDecoder()
        decoder.adoptInputCodecForTest(Input(failing))
        decoder.randomAccess.adoptDecodableReferencesForTest()
        val source = decoder.captureInputOwnership()
        decoder.decode(byteArrayOf(0, 0, 0, 1, 2, 1, 1), source.owner, source.epoch)
        val incident = decoder.incidentDecoder(nowElapsedMs = 1L)
        assertEquals(FeedDecoderErrorOrigin.SYNC, incident.origin)
        return incident.errorCall to decoder.errorLifetime.lastError?.journalLine()
    }

    @Test fun everyInputCallNamesItselfOnTheIncidentAndInTheJournal() {
        for (call in listOf(
            DecoderErrorCall.DEQUEUE_INPUT, DecoderErrorCall.GET_INPUT_BUFFER,
            DecoderErrorCall.FILL_INPUT, DecoderErrorCall.QUEUE_INPUT,
        )) {
            val (incidentCall, journal) = failingCall(call)
            assertEquals(call.wire, incidentCall)
            assertEquals(true, journal?.contains("call=${call.wire}"), journal)
        }
    }

    @Test fun aHealthyDecoderNamesNoCall() {
        assertEquals(null, HevcDecoder().incidentDecoder(nowElapsedMs = 1L).errorCall)
    }
}
