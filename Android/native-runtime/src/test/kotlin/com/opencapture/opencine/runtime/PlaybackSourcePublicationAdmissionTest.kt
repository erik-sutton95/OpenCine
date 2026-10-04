package com.opencapture.opencine.runtime

import java.util.concurrent.atomic.AtomicReference
import kotlin.test.*

/** Exercises the actual source/epoch gate used at GLES present and queued tap publication. */
class PlaybackSourcePublicationAdmissionTest {
    @Test fun queuedOldSourceCannotPresentAfterRealCurrentIdentityChanges() {
        val gate = InspectorPreviewSource()
        val current = AtomicReference<Any>("A")
        val admission: (Any) -> Boolean = { it == current.get() }
        gate.configure("A", true)
        gate.didLatch(gate.beginLatch())
        val old = gate.captureEpoch()
        current.set("B") // logical token is committed before Compose reconfigures the renderer
        assertFalse(gate.isCurrent(old, admission))
        var painted = false
        assertFalse(gate.present(admission) { painted = true })
        assertFalse(painted)
        gate.configure("B", true)
        gate.didLatch(gate.beginLatch())
        assertTrue(gate.present(admission) { painted = true })
        assertTrue(painted)
        assertFalse(gate.isCurrent(old, admission))
    }

    @Test fun capturedRootRetirementRejectsQueueWithoutErasingSuccessorLease() {
        val gate = InspectorPreviewSource()
        val currentRoot = AtomicReference("first-root")
        val first: (Any) -> Boolean = { currentRoot.get() == "first-root" }
        gate.configure("item", true); gate.didLatch(gate.beginLatch())
        val queued = gate.captureEpoch()
        currentRoot.set("second-root")
        assertFalse(gate.isCurrent(queued, first))
        assertFalse(gate.present(first) { error("Retired root cannot paint") })
        val successor: (Any) -> Boolean = { currentRoot.get() == "second-root" }
        gate.configure("successor", true); gate.didLatch(gate.beginLatch())
        assertTrue(gate.present(successor) {})
        assertFalse(gate.isCurrent(queued, first))
    }

    @Test fun optionalAdmissionRequiresActualLatchedReadinessAndRetirementAdvancesEpoch() {
        val gate = InspectorPreviewSource()
        val admission: (Any) -> Boolean = { it == "item" }
        gate.configure("item", false)
        assertFalse(gate.present(admission) { error("No decoded source frame") })
        gate.configure("item", true)
        assertFalse(gate.present(admission) { error("Ready metadata alone is not a latched frame") })
        gate.didLatch(gate.beginLatch())
        val before = gate.captureEpoch()
        assertTrue(gate.present(admission) {})
        gate.configure("item", false)
        assertFalse(gate.isCurrent(before, admission))
        assertFalse(gate.present(admission) {})
    }

    @Test fun defaultCallerKeepsOriginalUngatedPictureBehavior() {
        val gate = InspectorPreviewSource()
        var painted = 0
        assertTrue(gate.present(null) { painted++ })
        assertEquals(1, painted)
        gate.configure("item", false)
        assertTrue(gate.present(null) { painted++ })
        assertEquals(2, painted)
    }
}
