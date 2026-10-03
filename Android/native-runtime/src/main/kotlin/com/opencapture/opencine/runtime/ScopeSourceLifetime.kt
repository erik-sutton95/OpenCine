package com.opencapture.opencine.runtime

/** A mounted native renderer owns one publication lease, including source invalidation. */
class ScopeSourceLifetime(private val bus: ScopeSampleBus, private val role: ScopeSampleBus.Role) {
    private var attached = false
    private var active = false
    private var retired = false
    private var owner: ScopeSampleBus.Source? = null
    val ownedSource: ScopeSampleBus.Source? @Synchronized get() = owner
    val source: ScopeSampleBus.Source? @Synchronized get() = owner.takeIf { active }

    @Synchronized fun attach() {
        if (attached) return
        retired = false
        attached = true
        reconcile()
    }
    @Synchronized fun detach() {
        if (!attached) return
        attached = false
        reconcile()
    }
    @Synchronized fun invalidate(active: Boolean) {
        this.active = active
        reconcile()
    }
    private fun reconcile() {
        val previous = owner
        if (previous != null && !bus.isCurrent(previous)) {
            retired = true
            owner = null
            return
        }
        // Keep a lease while mounted, including when assists are off. Otherwise an old
        // inactive renderer could reopen after a successor mounts and steal publication.
        owner = if (!retired && attached) {
            if (previous == null) bus.openSource(role) else bus.replaceSource(previous)
        } else {
            bus.closeSource(previous)
            null
        }
    }
}
