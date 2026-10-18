package com.opencapture.opencine.media

import kotlin.test.Test
import kotlin.test.assertEquals

class CodecFailurePolicyTest {
    @Test fun reclaimedAndRecoverableCodecsAreRebuiltAndTransientOnesRetried() {
        // PA-A: codec:1101 (ERROR_RECLAIMED) after 68 s of healthy picture. The
        // resource manager took the instance back; only a new codec decodes again.
        assertEquals(
            CodecFailureAction.REBUILD,
            CodecFailurePolicy.action(errorCode = 1101, isTransient = false, isRecoverable = false),
        )
        // Recoverable: the instance cannot continue but a fresh configure can.
        assertEquals(
            CodecFailureAction.REBUILD,
            CodecFailurePolicy.action(errorCode = -2147479551, isTransient = false, isRecoverable = true),
        )
        // Transient: the same call may succeed shortly; codec and references stay.
        assertEquals(
            CodecFailureAction.RETRY,
            CodecFailurePolicy.action(errorCode = -2147479551, isTransient = true, isRecoverable = false),
        )
        // Fatal and unclassified: recorded; the output-silence repair keeps ownership.
        assertEquals(
            CodecFailureAction.REPORT,
            CodecFailurePolicy.action(errorCode = -2147479551, isTransient = false, isRecoverable = false),
        )
    }
}
