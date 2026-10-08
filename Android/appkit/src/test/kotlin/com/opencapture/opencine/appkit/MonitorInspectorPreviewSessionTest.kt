package com.opencapture.opencine.appkit

import com.opencapture.opencine.media.FeedEffectsRenderPlan
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** SIMULATED delivery, stepped manually; the real native worker remains in native-runtime. */
class MonitorInspectorPreviewSessionTest {
    @Test fun currentOwnerReceivesPicture() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        val owner = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        client.deliver(owner, "current")
        assertEquals("current", session.image.value)
        assertTrue(session.isCurrent(owner))
    }

    @Test fun missingActiveOwnerDoesNotRender() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        session.update(FeedEffectsRenderPlan.IDENTITY)
        assertEquals(0, client.opens.size)
        assertEquals(0, client.updates.size)
        assertNull(session.image.value)
    }

    @Test fun retiredOwnerCannotPublish() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        val owner = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        session.deactivate(owner)
        client.deliver(owner, "late")
        assertNull(session.image.value)
        assertFalse(session.isCurrent(owner))
        assertSame(owner, client.closes.single())
    }

    @Test fun oldOwnerCannotCloseSuccessor() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        val old = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        val successor = session.activate(true, FeedEffectsRenderPlan.IDENTITY)
        session.deactivate(old)
        client.deliver(successor, "current")
        client.deliver(old, null)
        assertTrue(session.isCurrent(successor))
        assertEquals("current", session.image.value)
        assertSame(old, client.closes.single())
    }

    @Test fun replacementDuringOpenPreservesSuccessor() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        var successor: Any? = null
        client.onOpen = {
            client.onOpen = null
            successor = session.activate(true, FeedEffectsRenderPlan.IDENTITY)
            client.deliver(successor!!, "current")
        }
        val old = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        client.deliver(old, "late")
        assertTrue(session.isCurrent(successor!!))
        assertFalse(session.isCurrent(old))
        assertEquals("current", session.image.value)
    }

    @Test fun replacementDuringClosePreservesSuccessor() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        val old = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        var successor: Any? = null
        client.onClose = {
            client.onClose = null
            successor = session.activate(true, FeedEffectsRenderPlan.IDENTITY)
            client.deliver(successor!!, "current")
        }
        session.deactivate(old)
        assertTrue(session.isCurrent(successor!!))
        assertEquals("current", session.image.value)
        client.deliver(old, null)
        assertEquals("current", session.image.value)
    }

    @Test fun oldOuterActivationCannotOverwriteCloseSuccessor() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        var successor: Any? = null
        client.onClose = {
            client.onClose = null
            successor = session.activate(true, FeedEffectsRenderPlan.IDENTITY)
            client.deliver(successor!!, "current")
        }
        val refused = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        assertFalse(session.isCurrent(refused))
        assertTrue(session.isCurrent(successor!!))
        assertEquals(2, client.opens.size)
        assertEquals("current", session.image.value)
    }

    @Test fun updateUsesCapturedOwnerAndLatestPlan() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        val owner = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        val changed = FeedEffectsRenderPlan.IDENTITY.withPreviewOwner(Any())
        session.update(changed)
        assertSame(owner, client.updates.single().first)
        assertSame(changed, client.updates.single().second)
    }

    @Test fun updateReentryCannotClearSuccessorPicture() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        val old = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        var successor: Any? = null
        client.onUpdate = {
            client.onUpdate = null
            successor = session.activate(true, FeedEffectsRenderPlan.IDENTITY)
            client.deliver(successor!!, "current")
            client.deliver(old, null)
        }
        session.update(FeedEffectsRenderPlan.IDENTITY)
        assertTrue(session.isCurrent(successor!!))
        assertEquals("current", session.image.value)
    }

    @Test fun activeNilDeliveryClearsPicture() {
        val client = Client()
        val session = MonitorInspectorPreviewSession(client)
        val owner = session.activate(false, FeedEffectsRenderPlan.IDENTITY)
        client.deliver(owner, "current")
        client.deliver(owner, null)
        assertNull(session.image.value)
        assertTrue(session.isCurrent(owner))
    }

    private class Client : MonitorInspectorPreviewClient<String> {
        val opens = mutableListOf<Any>()
        val closes = mutableListOf<Any>()
        val updates = mutableListOf<Pair<Any, FeedEffectsRenderPlan>>()
        private val receivers = mutableMapOf<Any, (String?) -> Unit>()
        var onOpen: (() -> Unit)? = null
        var onClose: (() -> Unit)? = null
        var onUpdate: (() -> Unit)? = null
        override fun open(owner: Any, playback: Boolean, plan: FeedEffectsRenderPlan, receive: (String?) -> Unit) {
            opens += owner
            receivers[owner] = receive
            onOpen?.invoke()
        }
        override fun update(owner: Any, plan: FeedEffectsRenderPlan) { updates += owner to plan; onUpdate?.invoke() }
        override fun close(owner: Any) { closes += owner; onClose?.invoke() }
        fun deliver(owner: Any, picture: String?) { receivers.getValue(owner)(picture) }
    }
}
