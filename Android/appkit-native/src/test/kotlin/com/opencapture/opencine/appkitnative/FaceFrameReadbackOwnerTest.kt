package com.opencapture.opencine.appkitnative

import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.StreamGeneration

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** SIMULATED held native completions, exercising the proposed production owner without sleeps. */
class FaceFrameReadbackOwnerTest {
    private class Pixels {
        var releases = 0
        fun release() { releases++ }
    }

    private class Frame(val pixels: Pixels) {
        fun release() = pixels.release()
    }

    private class Source(var identity: Any = Any()) {
        var epoch: MonitorFaceReadbackEpoch? = MonitorFaceReadbackEpoch(CameraSessionID(), ControlEpoch(1))
        var factories = 0
        var discards = 0
        val admitted = mutableListOf<Frame>()
    }

    private class PumpJob(var active: Boolean = true)

    private class Host {
        val first = Source()
        var current = first
        var pumpJob = PumpJob()
        val owner = FaceFrameReadbackOwner({ current }, { it.identity }, { it.epoch })
        var lifetime = assertNotNull(owner.activate())
        var duringFactory: () -> Unit = {}
        var failConstruction = false

        fun replace(source: Source) {
            owner.retire(lifetime)
            current = source
            lifetime = assertNotNull(owner.activate())
        }

        fun hold(): HeldCopy {
            val originalJob = pumpJob
            val request = assertNotNull(owner.begin { originalJob.active })
            return HeldCopy(request, Pixels())
        }

        inner class HeldCopy(
            val request: FaceFrameReadbackOwner.Request<Source>,
            val pixels: Pixels,
        ) {
            fun finish(copied: Boolean = true) {
                owner.complete(request, copied, pixels::release,
                    construct = { source, release ->
                        source.factories++
                        if (failConstruction) {
                            release()
                            null
                        } else {
                            Frame(pixels).also { duringFactory() }
                        }
                    },
                    discard = { source, frame -> source.discards++; frame.release() },
                    consume = { source, frame -> source.admitted += frame })
            }
        }
    }

    @Test fun successorActiveCannotAdmitAnOlderCameraBitmap() {
        val host = Host()
        val old = host.hold()
        val successor = Source()
        host.replace(successor)
        assertNull(host.owner.begin { true }, "the native copy still owns its one slot")
        assertEquals(0, old.pixels.releases, "retirement cannot recycle a native write destination")
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(0, successor.factories)
        assertEquals(1, old.pixels.releases)
        val next = host.hold()
        next.finish()
        assertEquals(1, successor.admitted.size, "the active successor still accepts its own bitmap")
        successor.admitted.single().release()
        assertEquals(1, next.pixels.releases)
    }

    @Test fun stableAdapterChangingPictureIdentityRejectsHeldSuccess() {
        val host = Host()
        val old = host.hold()
        host.first.identity = Any()
        // Deliberately no recomposition/lifetime activation: the live getter itself fences delivery.
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(0, host.first.admitted.size)
        assertEquals(1, old.pixels.releases)
    }

    @Test fun terminalDisposalCannotAdmitOrReopen() {
        val host = Host()
        val old = host.hold()
        host.owner.close()
        assertEquals(0, old.pixels.releases)
        assertNull(host.owner.activate())
        assertNull(host.owner.begin { true })
        old.finish()
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(1, old.pixels.releases)
    }

    @Test fun canceledOriginalCoroutineCannotUseSuccessorCoroutineLiveness() {
        val host = Host()
        val old = host.hold()
        host.pumpJob.active = false
        host.pumpJob = PumpJob()
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(1, old.pixels.releases)
        val next = host.hold()
        next.finish()
        host.first.admitted.single().release()
        assertEquals(1, next.pixels.releases)
    }

    @Test fun validSameSourceTransfersOnceAndNeverRecyclesBeforeConsumerFinishes() {
        val host = Host()
        val copy = host.hold()
        copy.finish()
        copy.finish()
        assertEquals(1, host.first.factories)
        assertEquals(1, host.first.admitted.size)
        assertEquals(0, host.first.discards)
        assertEquals(0, copy.pixels.releases, "the detector may still be reading these pixels")
        host.first.admitted.single().release()
        assertEquals(1, copy.pixels.releases)
    }

    @Test fun oldCallbackCannotClearOrRecycleAnActiveSuccessorRequest() {
        val host = Host()
        val old = host.hold()
        host.replace(Source())
        old.finish()
        val next = host.hold()
        old.finish(copied = false)
        assertNull(host.owner.begin { true })
        assertEquals(1, old.pixels.releases)
        assertEquals(0, next.pixels.releases)
        next.finish()
        host.current.admitted.single().release()
        assertEquals(1, next.pixels.releases)
    }

    @Test fun returningToTheSameCameraDoesNotRestoreARetiredLifetime() {
        val host = Host()
        val original = host.first
        val old = host.hold()
        host.replace(Source())
        host.replace(original)
        old.finish()
        assertEquals(0, original.factories)
        assertEquals(1, old.pixels.releases)
    }

    @Test fun retiringAnOlderLifetimeCannotRetireItsSuccessor() {
        val host = Host()
        val olderLifetime = host.lifetime
        host.replace(Source())
        host.owner.retire(olderLifetime)
        val next = host.hold()
        next.finish()
        assertEquals(1, host.current.admitted.size)
        host.current.admitted.single().release()
        assertEquals(1, next.pixels.releases)
    }

    @Test fun sourceReplacementDuringConstructionDiscardsThroughOriginalFrameOwner() {
        val host = Host()
        val copy = host.hold()
        val successor = Source()
        host.duringFactory = { host.replace(successor) }
        copy.finish()
        assertEquals(1, host.first.factories)
        assertEquals(1, host.first.discards)
        assertEquals(0, host.first.admitted.size)
        assertEquals(0, successor.admitted.size)
        assertEquals(1, copy.pixels.releases)
    }

    @Test fun disposalDuringConstructionDiscardsTheUnsubmittedFrameOnce() {
        val host = Host()
        val copy = host.hold()
        host.duringFactory = { host.owner.close() }
        copy.finish()
        copy.finish()
        assertEquals(1, host.first.discards)
        assertEquals(0, host.first.admitted.size)
        assertEquals(1, copy.pixels.releases)
    }

    @Test fun failedNativeCopyOrSynchronousRequestFailureReleasesOnce() {
        val host = Host()
        val failed = host.hold()
        failed.finish(copied = false)
        failed.finish(copied = false)
        assertEquals(0, host.first.factories)
        assertEquals(1, failed.pixels.releases)
        val next = host.hold()
        next.finish()
        host.first.admitted.single().release()
        assertEquals(1, next.pixels.releases)
    }

    @Test fun unsuccessfulConstructionDoesNotReleaseAgainOrLeakTheSlot() {
        val host = Host()
        val failed = host.hold()
        host.failConstruction = true
        failed.finish()
        assertEquals(1, failed.pixels.releases)
        assertEquals(0, host.first.admitted.size)
        host.failConstruction = false
        val next = host.hold()
        next.finish()
        host.first.admitted.single().release()
        assertEquals(1, next.pixels.releases)
    }

    @Test fun noBitmapAbandonsOnlyItsOwnRequest() {
        val host = Host()
        val noBitmap = assertNotNull(host.owner.begin { true })
        host.owner.abandon(noBitmap)
        val next = host.hold()
        host.owner.abandon(noBitmap)
        assertNull(host.owner.begin { true })
        next.finish()
        host.first.admitted.single().release()
        assertEquals(1, next.pixels.releases)
    }

    @Test fun sameAdapterAndSavedCameraRejectReconnectWithoutRecomposition() {
        val host = Host()
        val old = host.hold()
        host.first.epoch = MonitorFaceReadbackEpoch(CameraSessionID(), ControlEpoch(1))
        // No change to camera identity, source adapter, lifetime or coroutine: only the real token changes.
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(1, old.pixels.releases)
        val current = host.hold()
        current.finish()
        host.first.admitted.single().release()
        assertEquals(1, current.pixels.releases)
    }

    @Test fun knownSessionWithNewRecoveryEpochRejectsItsOldReadback() {
        val host = Host()
        val old = host.hold()
        val epoch = assertNotNull(host.first.epoch)
        host.first.epoch = epoch.copy(control = epoch.control.next())
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(1, old.pixels.releases)
    }

    @Test fun unknownEpochRefusesNewAndPreviouslyCapturedReadbacks() {
        val host = Host()
        val old = host.hold()
        host.first.epoch = null
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(1, old.pixels.releases)
        assertNull(host.owner.begin { true })
    }

    @Test fun nativeStreamReplacementRejectsOldReadbackEvenWhenControlSessionIsRetained() {
        val host = Host()
        val control = assertNotNull(host.first.epoch)
        host.first.epoch = control.copy(stream = StreamGeneration(1))
        val old = host.hold()
        host.first.epoch = control.copy(stream = StreamGeneration(2))
        old.finish()
        assertEquals(0, host.first.factories)
        assertEquals(1, old.pixels.releases)
    }
}
