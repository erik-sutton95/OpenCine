package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Where a camera was last reached on a Wi-Fi or hotspot setup's network: the network, the camera's
 * address there and the serial its control link proved (Swift `LunaStationHost`). A backend keeps one
 * per camera in memory; [LunaBackend.rememberStationHost] lets a caller that kept it elsewhere (a
 * Multiview journal) hand it back.
 */
data class LunaStationHost(val network: String, val hotspot: Boolean, val host: String, val serial: String) {
    /** Whether this address belongs to [network] (same name, same kind of network). */
    fun isOn(network: LunaStationNetwork): Boolean = this.network == network.ssid && hotspot == network.hotspot
}

/**
 * LAN-first reconnect for a Wi-Fi or hotspot setup (Swift `LunaStationReconnect`): a camera last
 * reached on this network is opened at its known address first, with the serial check and without
 * Bluetooth ([LunaStationOpen]); only when that fails is it moved over Bluetooth again (which also
 * finds it by searching). A known address another connection of this app holds is never tried.
 */
internal object LunaStationReconnect {
    /** How the connect reached the camera. */
    enum class Path {
        /** At its known address on the network, without Bluetooth. */
        DIRECT,
        /** Over Bluetooth: moved onto the network and found there. */
        BLUETOOTH,
    }

    /**
     * [direct] when [LunaStationOpen] may open [known] on [network] (not in [inUse]); when it fails,
     * [move]. Cancellation, Local Network permission denial (the move's search would be refused too),
     * this phone failing to join the network (the move would strand the camera there) and a failure
     * after [reached] (the camera was live; the link then dropped) end the connect instead of moving
     * the camera. [reached] is Android only: the control link runs for the whole session inside
     * [direct], so it is what tells a failed open from a session that ended (on iOS `direct` ends once
     * the control link is open).
     */
    suspend fun run(
        known: LunaStationHost?, network: LunaStationNetwork, inUse: Set<String>,
        reached: () -> Boolean = { false }, log: (String) -> Unit = {},
        direct: suspend (LunaStationHost) -> Unit, move: suspend () -> Unit,
    ): Path {
        if (known != null && LunaStationOpen.refusal(known, network, inUse) == null) {
            try {
                direct(known)
                return Path.DIRECT
            } catch (error: Exception) {
                currentCoroutineContext().ensureActive()
                // A step's own timeout is no cancellation of the connect: it falls back.
                if ((error is CancellationException && error !is TimeoutCancellationException) || reached()) throw error
                val failure = (error as? LunaStationFailure)?.failure
                val reason = failure?.reason
                if (reason is ConnectionFailure.Reason.Permission && reason.permission == ConnectionFailure.Permission.LOCAL_NETWORK) throw error
                if (reason == ConnectionFailure.Reason.JoinFailed) throw error
                log("luna: the camera's known address did not answer as it (${failure?.code ?: "unexpected"}); moving it over Bluetooth")
            }
        }
        move()
        return Path.BLUETOOTH
    }
}
