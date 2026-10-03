package com.opencapture.opencine.runtime

import java.util.concurrent.atomic.AtomicLong

/** Only callbacks from the current mounted native renderer may reach its consumer. */
class NativeRenderLifetime {
    private val generation = AtomicLong(0)
    @Volatile private var active = false
    @Synchronized fun start(): Long { active = true; return generation.incrementAndGet() }
    @Synchronized fun stop() { active = false; generation.incrementAndGet() }
    fun isCurrent(ticket: Long): Boolean = active && generation.get() == ticket
}
