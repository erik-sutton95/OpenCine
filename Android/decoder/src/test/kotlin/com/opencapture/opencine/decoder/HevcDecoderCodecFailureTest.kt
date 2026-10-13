package com.opencapture.opencine.decoder

import com.opencapture.opencine.media.CodecFailureAction
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class HevcDecoderCodecFailureTest {
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
