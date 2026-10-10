package com.opencapture.opencine.relay

import java.util.UUID
import java.util.concurrent.Executors
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayHostCommandGateTest {
    private fun receipt(): RelayHostControl.Admission = RelayHostControl.Admission(UUID.randomUUID(), UUID.randomUUID(), 7)

    @Test fun currentPublicationAdmitsExactlyItsSourcePeerRevisionAndSavedIdentity() {
        val gate = RelayHostCommandGate()
        val admission = receipt()
        assertTrue(gate.publish(gate.publication, admission.source, admission.revision, admission, "saved"))
        assertTrue(gate.admits(admission))
        assertTrue(gate.admits(admission.source, admission.revision))
        assertTrue(gate.admits("saved"))
        assertFalse(gate.admits(""))
        assertFalse(gate.admits("another"))
        assertFalse(gate.admits(UUID.randomUUID(), admission.revision))
    }

    @Test fun immediateRetirementBlocksAQueuedOldPublicationBeforeItsTransportRuns() {
        val gate = RelayHostCommandGate()
        val queued = gate.publication
        val admission = receipt()
        gate.publish(queued, admission.source, admission.revision, admission, "saved")
        val successor = gate.retire()
        assertTrue(gate.isCurrent(successor))
        assertFalse(gate.isCurrent(queued))
        assertFalse(gate.admits(admission))
        assertFalse(gate.admits("saved"))
        assertFalse(gate.publish(queued, admission.source, admission.revision, admission, "saved"))
        assertFalse(gate.admits(admission))
    }

    @Test fun successorPublicationSurvivesAnOldQueueFinallyAndSecondRetirement() {
        val gate = RelayHostCommandGate()
        val old = gate.publication
        val first = gate.retire()
        val newest = gate.retire()
        val admission = receipt()
        assertFalse(gate.publish(first, admission.source, admission.revision, admission, "saved"))
        assertTrue(gate.publish(newest, admission.source, admission.revision, admission, "saved"))
        assertFalse(gate.publish(old, UUID.randomUUID(), 0, null, null))
        assertTrue(gate.admits(admission))
    }

    @Test fun wrongOwnerCannotBorrowARepeatedSourceOrPublicationGeneration() {
        val first = RelayHostCommandGate()
        val second = RelayHostCommandGate()
        val admission = receipt()
        assertFalse(second.publish(first.publication, admission.source, admission.revision, admission, "saved"))
        assertFalse(second.admits(admission))
    }

    @Test fun alreadyEnteredNativeWorkCompletesWhileTheNextUnsentReadFailsOffActor() {
        val gate = RelayHostCommandGate()
        val admission = receipt()
        gate.publish(gate.publication, admission.source, admission.revision, admission, "saved")
        val entered = gate.admits(admission)
        gate.retire()
        val executor = Executors.newSingleThreadExecutor()
        try { assertTrue(entered && !executor.submit<Boolean> { gate.admits(admission) }.get()) }
        finally { executor.shutdownNow() }
    }
}
