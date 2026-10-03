package com.opencapture.opencine.runtime

import com.opencapture.opencine.media.ScopeAssistBundle

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ScopeSampleBusTest {
    @Test fun retiredSourceCannotPublishOrClearSuccessor() {
        val bus = ScopeSampleBus()
        val old = bus.openSource()
        val queued = { bus.publish(old, ScopeAssistBundle(revision = 1)) }
        val successor = bus.openSource()
        val current = ScopeAssistBundle(revision = 2)
        assertTrue(bus.publish(successor, current))
        assertFalse(queued())
        bus.closeSource(old)
        assertEquals(current, bus.bundle)
        assertEquals(1L, bus.generation)
        assertTrue(bus.isCurrent(successor))
        bus.closeSource(successor)
        assertFalse(bus.publish(successor, current))
    }
    @Test fun independentMonitorsKeepIndependentPublications() {
        val first = ScopeSampleBus()
        val second = ScopeSampleBus()
        val a = first.openSource()
        val b = second.openSource()
        val held = ScopeAssistBundle(revision = 3)
        assertTrue(first.publish(a, held))
        second.closeSource(b)
        assertEquals(held, first.bundle)
        assertTrue(second.bundle.isEmpty)
    }
    @Test fun playbackWithoutAFrameCannotShowHeldLiveSamples() {
        val bus = ScopeSampleBus()
        val live = bus.openSource()
        val held = ScopeAssistBundle(revision = 1)
        assertTrue(bus.publish(live, held))
        val retired = bus.openSource(ScopeSampleBus.Role.PLAYBACK)
        assertTrue(bus.bundle.isEmpty)
        val successor = bus.openSource(ScopeSampleBus.Role.PLAYBACK)
        val clip = ScopeAssistBundle(revision = 2)
        assertTrue(bus.publish(successor, clip))
        assertFalse(bus.publish(retired, ScopeAssistBundle(revision = 3)))
        bus.closeSource(retired)
        assertEquals(clip, bus.bundle)
        bus.closeSource(successor)
        assertEquals(held, bus.bundle)
        assertTrue(bus.isCurrent(live))
    }
    @Test fun retiredRendererCannotReopenOverSuccessorOnSourceReset() {
        val bus = ScopeSampleBus()
        val retired = ScopeSourceLifetime(bus, ScopeSampleBus.Role.LIVE)
        retired.invalidate(active = true)
        retired.attach()
        val old = retired.source
        retired.invalidate(active = false)
        assertEquals(null, retired.source)
        val successor = ScopeSourceLifetime(bus, ScopeSampleBus.Role.LIVE)
        successor.invalidate(active = true)
        successor.attach()
        val held = ScopeAssistBundle(revision = 2)
        assertTrue(bus.publish(successor.source, held))
        retired.invalidate(active = true)
        retired.invalidate(active = false)
        retired.invalidate(active = true)
        assertEquals(held, bus.bundle)
        assertTrue(bus.isCurrent(successor.source))
        assertFalse(bus.publish(old, ScopeAssistBundle(revision = 3)))
        assertEquals(null, bus.replaceSource(old))
        retired.detach()
        assertEquals(held, bus.bundle)
    }

}
