package com.opencapture.opencine.runtime

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NativePreviewLifetimeTest {
    @Test fun replacedSourceCannotPublishOrInvalidateTheSuccessorPreview() {
        val bus = ScopeSampleBus()
        val gate = InspectorPreviewAdmission(bus)
        val tool = Any()
        gate.activate(tool, false)
        val old = bus.openSource()
        val pending = assertNotNull(gate.acquire(tool, false, 0, old))
        val successor = bus.openSource()
        assertFalse(gate.isCurrent(pending))
        assertFalse(gate.invalidateSource(tool, old))
        assertNull(gate.acquire(tool, false, 1_000_000_000, successor), "Keep one job until discard")
        gate.complete(pending)
        val current = assertNotNull(gate.acquire(tool, false, 1_000_000_000, successor))
        assertFalse(gate.invalidateSource(tool, old), "Late teardown cannot clear the new preview")
        assertTrue(gate.isCurrent(current))
        assertTrue(gate.invalidateSource(tool, successor))
        assertFalse(gate.isCurrent(current))
        gate.complete(current)
        bus.closeSource(successor)
        assertNull(gate.acquire(tool, false, 2_000_000_000, successor))
    }

    @Test fun playbackAndOtherMonitorCannotSupplyTheLivePreview() {
        val bus = ScopeSampleBus()
        val gate = InspectorPreviewAdmission(bus)
        val owner = Any()
        gate.activate(owner, false)
        val live = bus.openSource()
        val clip = bus.openSource(ScopeSampleBus.Role.PLAYBACK)
        val other = ScopeSampleBus().openSource()
        assertNull(gate.acquire(owner, false, 0, clip))
        assertNull(gate.acquire(owner, false, 0, other))
        assertFalse(gate.invalidateSource(owner, clip))
        val pending = assertNotNull(gate.acquire(owner, false, 0, live))
        bus.closeSource(clip)
        assertTrue(gate.isCurrent(pending))
    }

    @Test fun retiredRendererCallbacksCannotReachAReattachedConsumer() {
        val lifetime = NativeRenderLifetime()
        val old = lifetime.start()
        assertTrue(lifetime.isCurrent(old))
        lifetime.stop()
        assertFalse(lifetime.isCurrent(old))
        val current = lifetime.start()
        assertFalse(lifetime.isCurrent(old), "An old SurfaceTexture or posted callback remains retired")
        assertTrue(lifetime.isCurrent(current))
        lifetime.stop()
        assertFalse(lifetime.isCurrent(current))
    }
}
