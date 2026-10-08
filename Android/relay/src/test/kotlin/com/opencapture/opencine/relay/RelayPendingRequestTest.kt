package com.opencapture.opencine.relay

import java.util.UUID
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** SIMULATED mirror of RelayPendingRequestTests; no wire or lease constants change. */
class RelayPendingRequestTest {
    @Test fun rejectedRequestDoesNotAdvanceRequestOrLeaseRevision() {
        val control = RelayHostControl()
        val peer = UUID.randomUUID()
        control.register(peer, "SIMULATED watcher", false)
        assertFalse(control.request(peer, true))
        control.register(peer, "SIMULATED watcher", true)
        assertFalse(control.request(peer, false))
        assertEquals(0L, control.requestRevision)
        assertEquals(0L, control.revision)
        assertNull(control.pendingRequestRevision)
        assertNull(control.pendingRequest)
    }
    @Test fun declineAndSamePeerRequestHaveDistinctReceiptsWithoutChangingLeaseRevision() {
        val control = RelayHostControl()
        val peer = UUID.randomUUID()
        control.register(peer, "SIMULATED watcher", true)
        assertTrue(control.request(peer, true))
        val first = assertNotNull(control.pendingRequest)
        assertTrue(control.declinePending(first))
        assertNull(control.pendingRequestRevision)
        assertTrue(control.request(peer, true))
        val next = assertNotNull(control.pendingRequest)
        assertEquals(first.source, next.source)
        assertEquals(first.peer, next.peer)
        assertEquals(first.requestRevision + 1, next.requestRevision)
        assertEquals(0L, control.revision)
        assertFalse(control.admits(first))
        assertTrue(control.admits(next))
    }
    @Test fun staleGrantCannotConsumeRepeatedRequest() {
        val control = RelayHostControl()
        val peer = UUID.randomUUID()
        control.register(peer, "SIMULATED watcher", true)
        assertTrue(control.request(peer, true))
        val old = assertNotNull(control.pendingRequest)
        control.declinePending()
        assertTrue(control.request(peer, true))
        val current = assertNotNull(control.pendingRequest)
        assertFalse(control.grantPending(old))
        assertNull(control.holder)
        assertEquals(current, control.pendingRequest)
        assertTrue(control.grantPending(current))
        assertEquals(peer, control.holder)
        assertNull(control.pendingRequestRevision)
        assertEquals(1L, control.revision)
    }
    @Test fun staleDeclineCannotConsumeRepeatedRequest() {
        val control = RelayHostControl()
        val peer = UUID.randomUUID()
        control.register(peer, "SIMULATED watcher", true)
        assertTrue(control.request(peer, true))
        val old = assertNotNull(control.pendingRequest)
        control.declinePending()
        assertTrue(control.request(peer, true))
        val current = assertNotNull(control.pendingRequest)
        assertFalse(control.declinePending(old))
        assertEquals(current, control.pendingRequest)
        assertTrue(control.declinePending(current))
        assertNull(control.pendingRequest)
        assertEquals(0L, control.revision)
    }
    @Test fun sourceAndPeerReplacementCannotReplayOldRequest() {
        val control = RelayHostControl()
        val peer = UUID.randomUUID()
        val successor = UUID.randomUUID()
        control.register(peer, "same label", true)
        assertTrue(control.request(peer, true))
        val old = assertNotNull(control.pendingRequest)
        control.register(successor, "same label", true)
        assertTrue(control.request(successor, true))
        val next = assertNotNull(control.pendingRequest)
        assertFalse(control.grantPending(old))
        assertFalse(control.declinePending(old))
        assertEquals(next, control.pendingRequest)
        control.resetSource()
        control.register(peer, "same label", true)
        assertTrue(control.request(peer, true))
        assertFalse(control.grantPending(old))
        assertFalse(control.declinePending(old))
        assertNotEquals(old.source, control.pendingRequest?.source)
        assertEquals(peer, control.pending)
    }
    @Test fun acceptedRequestsDoNotRevokeHeldCommandAdmission() {
        val control = RelayHostControl()
        val holder = UUID.randomUUID()
        val requester = UUID.randomUUID()
        control.register(holder, "SIMULATED holder", true)
        assertTrue(control.request(holder, true) && control.grantPending())
        val command = assertNotNull(control.admission(holder))
        val revision = control.revision
        control.register(requester, "SIMULATED requester", true)
        assertTrue(control.request(requester, true))
        val request = assertNotNull(control.pendingRequest)
        assertTrue(control.admits(command))
        assertEquals(revision, control.revision)
        assertTrue(control.declinePending(request))
        assertTrue(control.admits(command))
    }
}
