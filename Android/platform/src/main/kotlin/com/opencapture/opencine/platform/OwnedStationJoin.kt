package com.opencapture.opencine.platform

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The system side of one shared Wi-Fi path ([SharedWiFiPath]), behind [OwnedStationJoin] so the
 * owner rules run without Android.
 */
internal interface StationRequestPort {
    /** The phone's current Wi-Fi name, null when unknown (Location off, the permission denied). */
    fun currentSsid(): String?

    /** Whether the phone has an IPv4 address on Wi-Fi. */
    fun hasAddress(): Boolean

    /**
     * Asks the system to join [ssid] and waits for an address there. True once joined, with the
     * request left registered; false when it did not join, with its own request unregistered.
     */
    suspend fun request(ssid: String, password: String): Boolean

    /** Unregisters the path's request and its process binding. */
    fun letGo()
}

/**
 * Owners joining one shared network (several Multiview members and the stage itself): an owner's
 * join never takes the path from another owner. While someone else holds the path, a join for the
 * network they hold shares it (no second system request, whatever the phone can tell about its
 * current Wi-Fi name) and a join for another network is refused; a failed or cancelled join drops
 * nothing another owner holds. Joins run one at a time, so a second owner waits for the first's
 * request and then shares it. The path is let go only when the last owner releases it.
 */
internal class OwnedStationJoin(private val port: StationRequestPort, private val holders: PathHolders) {
    private val turn = Mutex()

    /** The network the owners hold, null while nobody holds the path or it was never named. */
    @Volatile var network: String? = null
        private set

    suspend fun join(ssid: String, password: String, owner: Any): Boolean = turn.withLock {
        if (holders.heldByOthersThan(owner)) {
            val held = network
            val shares = when {
                held != null -> held == ssid
                // The others use the phone's current Wi-Fi without having named it (a process
                // binding): share it unless the phone says it is another network.
                else -> port.hasAddress() && port.currentSsid().let { it == null || it == ssid }
            }
            if (!shares) return@withLock false
            network = ssid
            holders.hold(owner)
            return@withLock true
        }
        // Only this owner, or nobody, holds the path: it may move it.
        holders.release(owner)
        network = null
        if (port.currentSsid() == ssid && port.hasAddress()) {
            network = ssid
            holders.hold(owner)
            return@withLock true
        }
        port.letGo()
        if (!port.request(ssid, password)) return@withLock false
        network = ssid
        holders.hold(owner)
        true
    }

    /** [owner] holds the path without joining (this phone's hotspot, a process binding). */
    fun hold(owner: Any) {
        holders.hold(owner)
    }

    /** Drops [owner]'s hold; the last one lets the path go. True when nobody holds it any more. */
    fun release(owner: Any): Boolean {
        if (!holders.release(owner)) return false
        network = null
        port.letGo()
        return true
    }

    /** Lets go of the path, whoever holds it. */
    fun releaseAll() {
        holders.clear()
        network = null
        port.letGo()
    }
}
