package com.opencapture.opencine.relay

import java.util.UUID

/** Published admission across executors, mirroring the Swift host's existing locked gate. */
public class RelayHostCommandGate {
    public class Publication internal constructor(
        internal val owner: UUID,
        internal val generation: Long,
    )

    private val lock: Any = Any()
    private val owner: UUID = UUID.randomUUID()
    private var generation: Long = 0
    private var current: RelayHostControl.Admission? = null
    private var source: UUID? = null
    private var revision: Long? = null
    private var watcherID: String? = null

    public val publication: Publication
        get() = synchronized(lock) { Publication(owner, generation) }

    public fun isCurrent(publication: Publication): Boolean = synchronized(lock) {
        publication.owner == owner && publication.generation == generation
    }

    /** Immediate retirement; the old queue must publish its captured generation. */
    public fun retire(): Publication = synchronized(lock) {
        generation += 1
        current = null
        source = null
        revision = null
        watcherID = null
        Publication(owner, generation)
    }

    public fun publish(
        publication: Publication,
        source: UUID,
        revision: Long,
        admission: RelayHostControl.Admission?,
        watcherID: String?,
    ): Boolean = synchronized(lock) {
        if (publication.owner != owner || publication.generation != generation) return@synchronized false
        this.source = source
        this.revision = revision
        current = admission
        this.watcherID = watcherID
        true
    }

    public fun admits(source: UUID, revision: Long): Boolean = synchronized(lock) {
        this.source == source && this.revision == revision
    }

    public fun admits(admission: RelayHostControl.Admission): Boolean = synchronized(lock) { current == admission }

    public fun admits(watcherID: String): Boolean = synchronized(lock) {
        watcherID.isNotEmpty() && current != null && this.watcherID == watcherID
    }
}
