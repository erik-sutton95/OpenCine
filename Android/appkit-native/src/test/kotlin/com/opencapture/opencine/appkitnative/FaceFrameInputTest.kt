package com.opencapture.opencine.appkitnative

import java.util.concurrent.CancellationException
import kotlin.test.*

class FaceFrameInputTest {
    @Test fun initializerFailureReleasesPixelsAndStopsOnlyThisOptionalProducer() {
        var reports = 0
        var released = 0
        val input = FaceFrameInput { reports++ }
        assertNull(input.construct({ released++ }) { throw NullPointerException("SDK component unavailable") })
        assertTrue(input.failed)
        assertEquals(1, reports)
        assertEquals(1, released)
        assertNull(input.construct({ released++ }) { error("Failed producer must not retry the SDK every frame") })
        assertEquals(1, reports)
        assertEquals(2, released)
        // Operator retry creates a distinct producer; a made frame owns its pixels.
        val retry = FaceFrameInput { error("Unexpected retry failure") }
        assertEquals("frame", retry.construct({ released++ }) { "frame" })
        assertEquals(2, released)
        assertFalse(retry.failed)
    }

    @Test fun cancellationRemainsCancellationAndDoesNotBecomeAnSdkFailure() {
        var released = 0
        val input = FaceFrameInput { error("Cancellation must not be reported as SDK failure") }
        assertFailsWith<CancellationException> {
            input.construct({ released++ }) { throw CancellationException("retired") }
        }
        assertEquals(1, released)
        assertFalse(input.failed)
    }
}
