package com.opencapture.opencine.relay

import java.util.UUID

/** Captured from the actual native producer, checked around every runtime suspension. */
public class RelayFrameAdmission(public val isCurrent: () -> Boolean)

public object RelayJoinPolicy {
    public data class Refusal(public val reason: String, public val passcodeRequired: Boolean)

    public fun refusal(
        hello: RelayPeerHello,
        profile: RelayWireProfile,
        requiredPasscode: String,
        versionMismatchReason: String,
        passcodeReason: String = "This broadcast asks for a passcode.",
        requiresVersionMatch: Boolean = true,
    ): Refusal? {
        if (requiresVersionMatch && hello.version != profile.version) return Refusal(versionMismatchReason, false)
        val required = normalizedPasscode(requiredPasscode)
        if (required.isNotEmpty() && hello.passcode?.let(::normalizedPasscode) != required) {
            return Refusal(passcodeReason, true)
        }
        return null
    }

    /**
     * Both sides of a join compare passcodes without surrounding whitespace: the same trim as the
     * watcher passcode rule (monitor-ui `MonitorWatcherPasscodeRule.normalized`) and Swift's
     * `whitespacesAndNewlines`.
     */
    public fun normalizedPasscode(code: String): String = code.trim { ch ->
        ch in '\u0009'..'\u000D' || ch == '\u0085' || when (Character.getType(ch).toByte()) {
            Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
            else -> false
        }
    }
}

/** Confined by the runtime owner; one slow peer never consumes another peer's capacity. */
public class RelayPeerDelivery(public var authorized: Boolean = false) {
    public enum class FrameDecision { SEND, UNAVAILABLE, WRONG_CODEC, SATURATED, NEEDS_KEYFRAME }
    public var closing: Boolean = false
    public var acceptsHevc: Boolean = true
    public var needsKeyframe: Boolean = true
    public var inFlightFrames: Int = 0
    public var inFlightStates: Int = 0
        private set

    public fun admitFrame(isHevc: Boolean, isKeyframe: Boolean, depth: Int, jpegOnly: Boolean = false): FrameDecision {
        if (!authorized || closing) return FrameDecision.UNAVAILABLE
        if ((isHevc && !acceptsHevc) || (jpegOnly && acceptsHevc)) return FrameDecision.WRONG_CODEC
        if (inFlightFrames >= depth) {
            needsKeyframe = true
            return FrameDecision.SATURATED
        }
        if (needsKeyframe && !isKeyframe) return FrameDecision.NEEDS_KEYFRAME
        needsKeyframe = false
        inFlightFrames += 1
        return FrameDecision.SEND
    }

    public fun completeFrame(): Unit { inFlightFrames = (inFlightFrames - 1).coerceAtLeast(0) }
    public fun readyForFrame(depth: Int): Boolean = authorized && !closing && inFlightFrames < depth
    public fun admitState(maximumInFlight: Int = 1): Boolean {
        if (!authorized || closing || inFlightStates >= maximumInFlight) return false
        inFlightStates += 1
        return true
    }
    public fun completeState(): Unit { inFlightStates = (inFlightStates - 1).coerceAtLeast(0) }
}

/** A start/stop or actual producer replacement changes identity, including ABA reentry. */
public class RelayConnectionLifetime {
    public var token: UUID = UUID.randomUUID()
        private set
    public var active: Boolean = false
        private set

    public fun begin(): UUID { token = UUID.randomUUID(); active = true; return token }
    public fun retire(): Unit { token = UUID.randomUUID(); active = false }
    public fun admits(candidate: UUID): Boolean = active && token == candidate
}

/** Host control carries source/peer/lease admission instead of guessing from names or addresses. */
public class RelayHostControl(windowMillis: Long = RelayParkedControlLease.DEFAULT_WINDOW_MILLIS) {
    public data class Admission(public val source: UUID, public val peer: UUID, public val revision: Long)
    /** Identifies this request occurrence, including a repeat from the same peer. */
    public data class PendingRequest(public val source: UUID, public val peer: UUID, public val requestRevision: Long)
    private data class Peer(val name: String, val watcherID: String?, val authorized: Boolean)
    public var source: UUID = UUID.randomUUID()
        private set
    public var revision: Long = 0
        private set
    public var requestRevision: Long = 0
        private set
    public var holder: UUID? = null
        private set
    public var holderName: String? = null
        private set
    public var pending: UUID? = null
        private set
    public val pendingName: String? get() = peers[pending]?.name
    public val pendingRequestRevision: Long? get() = pending?.let { requestRevision }
    public val pendingRequest: PendingRequest? get() = pending?.let { PendingRequest(source, it, requestRevision) }
    public fun admits(request: PendingRequest): Boolean =
        pendingRequest == request && peers[request.peer]?.authorized == true
    private val peers = mutableMapOf<UUID, Peer>()
    private val lease = RelayParkedControlLease(windowMillis)

    public fun resetSource(): Unit {
        source = UUID.randomUUID(); revision += 1
        peers.clear(); holder = null; holderName = null; pending = null; lease.clear()
    }
    public fun register(id: UUID, name: String, authorized: Boolean): Unit { peers[id] = Peer(name, null, authorized) }
    public fun introduce(id: UUID, hello: RelayPeerHello, authorized: Boolean, nowMillis: Long): Boolean {
        if (id !in peers) return false
        peers[id] = Peer(hello.hostName, hello.watcherID, authorized)
        if (!authorized) {
            if (pending == id) pending = null
            if (holder == id) reclaim()
            return false
        }
        if (holder == id) holderName = hello.hostName
        if (holder == null && lease.claim(hello.watcherID, nowMillis)) {
            holder = id; holderName = hello.hostName; revision += 1
            return true
        }
        return false
    }
    public fun request(id: UUID, allowsControl: Boolean): Boolean {
        if (!allowsControl || peers[id]?.authorized != true) return false
        requestRevision += 1
        pending = id
        return true
    }
    public fun grantPending(): Boolean {
        val id = pending ?: return false
        val peer = peers[id] ?: return false
        if (!peer.authorized) return false
        holder = id; holderName = peer.name; pending = null; lease.clear(); revision += 1
        return true
    }
    public fun grantPending(request: PendingRequest): Boolean = admits(request) && grantPending()
    public fun declinePending(): Unit { pending = null }
    public fun declinePending(request: PendingRequest): Boolean {
        if (!admits(request)) return false
        declinePending()
        return true
    }
    public fun reclaim(): Unit { holder = null; holderName = null; pending = null; lease.clear(); revision += 1 }
    public fun drop(id: UUID, nowMillis: Long): Long? {
        val departing = peers.remove(id) ?: return null
        if (pending == id) pending = null
        if (holder != id) return null
        holder = null; revision += 1
        if (departing.authorized && lease.park(departing.watcherID, nowMillis)) return revision
        holderName = null
        return null
    }
    public fun expire(expected: Long, nowMillis: Long): Boolean {
        if (expected != revision || holder != null || holderName == null || lease.isParked(nowMillis)) return false
        reclaim()
        return true
    }
    public fun admission(id: UUID): Admission? =
        if (peers[id]?.authorized == true && holder == id) Admission(source, id, revision) else null
    public fun admits(value: Admission): Boolean =
        source == value.source && revision == value.revision && admission(value.peer) == value
}
