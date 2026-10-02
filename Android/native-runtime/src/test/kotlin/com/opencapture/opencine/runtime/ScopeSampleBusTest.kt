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
}
