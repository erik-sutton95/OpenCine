package com.opencapture.opencine.platform

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The join's loss and restart contract, shared by every product. */
class CameraApAvailabilityTrackerTest {
    @Test
    fun duplicateAvailabilityDoesNotCountAsARestart() {
        val tracker = CameraApAvailabilityTracker<String>()
        tracker.requestStarted()
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = true,
                reassociationGeneration = null,
            ),
            tracker.onAvailable("original"),
        )
        assertEquals(1L, tracker.nextReassociationGeneration())
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = false,
                reassociationGeneration = null,
            ),
            tracker.onAvailable("original"),
        )
    }

    @Test
    fun lossThenNewAvailabilityCompletesReassociation() {
        val tracker = CameraApAvailabilityTracker<String>()
        tracker.requestStarted()
        tracker.onAvailable("original")
        val expected = tracker.nextReassociationGeneration()
        assertTrue(tracker.onLost("original"))
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = true,
                reassociationGeneration = expected,
            ),
            tracker.onAvailable("replacement"),
        )
        assertTrue(tracker.hasEstablishedNetwork())
    }

    @Test
    fun staleLossCannotClearANewerNetwork() {
        val tracker = CameraApAvailabilityTracker<String>()
        tracker.requestStarted()
        tracker.onAvailable("original")
        assertFalse(tracker.onLost("stale"))
        assertTrue(tracker.onLost("original"))
    }

    @Test
    fun replacementCallbackCountsAsReassociationWhenAndroidOmitsLoss() {
        val tracker = CameraApAvailabilityTracker<String>()
        tracker.requestStarted()
        tracker.onAvailable("original")
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(
                shouldBind = true,
                reassociationGeneration = 1L,
            ),
            tracker.onAvailable("replacement"),
        )
    }

    @Test
    fun pathStaysReadyDuringReassociationGrace() {
        assertTrue(CameraApJoiner.isPathReady(hasBoundNetwork = true, inReassociationGrace = false))
        assertTrue(
            CameraApJoiner.isPathReady(hasBoundNetwork = false, inReassociationGrace = true),
            "onLost clears the Network object; process bind + grace still hold the camera AP",
        )
        assertTrue(!CameraApJoiner.isPathReady(hasBoundNetwork = false, inReassociationGrace = false))
    }

    @Test
    fun lossDoesNotClearEstablishedUntilRelease() {
        val tracker = CameraApAvailabilityTracker<String>()
        tracker.requestStarted()
        tracker.onAvailable("original")
        assertTrue(tracker.onLost("original"))
        assertTrue(tracker.hasEstablishedNetwork(), "live session must keep the SoftAP request")
    }

    @Test
    fun unavailableBlocksNewRestartWaitsWithoutPretendingTheNetworkWasLost() {
        val tracker = CameraApAvailabilityTracker<String>()
        tracker.requestStarted()
        tracker.onAvailable("original")
        tracker.onUnavailable()
        assertNull(tracker.nextReassociationGeneration())
        assertFalse(tracker.onLost("stale"))
        assertTrue(tracker.onLost("original"))
    }

    @Test
    fun releaseClearsTheOldRequestBeforeANewOneBegins() {
        val tracker = CameraApAvailabilityTracker<String>()
        tracker.requestStarted()
        tracker.onAvailable("original")
        tracker.release()
        assertNull(tracker.nextReassociationGeneration())
        assertEquals(
            CameraApAvailabilityTracker.AvailableResult(shouldBind = false, reassociationGeneration = null),
            tracker.onAvailable("stale"),
        )
    }
}
