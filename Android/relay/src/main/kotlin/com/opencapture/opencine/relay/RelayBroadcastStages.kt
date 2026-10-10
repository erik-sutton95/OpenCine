package com.opencapture.opencine.relay

import java.util.UUID

/** Independent bounded native stages. A completion is one-use and belongs to its captured stage. */
public class RelayBroadcastStages(public val encodingDepth: Int = 2, public val jpegDepth: Int = 2) {
    public enum class Lane { ENCODING, JPEG }
    public data class Ticket(public val stage: UUID, public val lane: Lane, public val id: UUID)
    private val lifetime = RelayConnectionLifetime()
    private val tickets = mutableMapOf<Lane, MutableSet<UUID>>()
    public val token: UUID get() = lifetime.token
    public val isActive: Boolean get() = lifetime.active

    init { require(encodingDepth > 0 && jpegDepth > 0); lifetime.begin() }
    public fun inFlight(lane: Lane): Int = tickets[lane]?.size ?: 0
    public fun admits(stage: UUID): Boolean = lifetime.admits(stage)
    public fun replace(): Unit { lifetime.begin(); tickets.clear() }
    public fun close(): Unit { lifetime.retire(); tickets.clear() }
    public fun admit(lane: Lane): Ticket? {
        val depth = if (lane == Lane.ENCODING) encodingDepth else jpegDepth
        if (!lifetime.active || inFlight(lane) >= depth) return null
        val id = UUID.randomUUID()
        tickets.getOrPut(lane) { mutableSetOf() }.add(id)
        return Ticket(token, lane, id)
    }
    public fun complete(ticket: Ticket): Boolean =
        lifetime.admits(ticket.stage) && tickets[ticket.lane]?.remove(ticket.id) == true
}
