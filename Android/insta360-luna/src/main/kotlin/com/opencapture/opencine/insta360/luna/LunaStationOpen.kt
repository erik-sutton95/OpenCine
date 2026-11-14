package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.ConnectionFailure
import com.opencapture.opencine.core.ConnectionPhase as CorePhase

/**
 * Opening a camera at its known address on a Wi-Fi or hotspot setup's network, LAN only (Swift
 * `LunaStationOpen`): no Bluetooth, and the control link proves the camera by the serial its last
 * connect read ([LunaBackend]'s `runLive` refuses another camera before anything else is sent). An
 * address that cannot be this camera's is refused before the phone joins anything: one from another
 * network, one without a proven serial, one another connection of this app holds.
 */
internal object LunaStationOpen {
    /** Why [host] cannot be opened on [network]; null when it may be. */
    fun refusal(host: LunaStationHost, network: LunaStationNetwork, inUse: Set<String>): ConnectionFailure? = when {
        !host.isOn(network) -> failure(
            ConnectionFailure.Reason.NotFound, "station.host-other-network", "The camera's last address is not on “${network.ssid}”.",
        )
        host.serial.isEmpty() -> failure(
            ConnectionFailure.Reason.Other, "station.host-unverified", "The camera's last address has no verified serial.",
        )
        host.host in inUse -> failure(
            ConnectionFailure.Reason.Other, "station.host-in-use", "Another camera connection of this app holds that address.",
        )
        else -> null
    }

    /**
     * [join] puts this phone on the network, [probe] asks the host for the Luna control port, and
     * [open] opens the control link at the host expecting the serial.
     */
    suspend fun run(
        host: LunaStationHost, network: LunaStationNetwork, inUse: Set<String>,
        join: suspend () -> Unit, probe: suspend (host: String) -> Boolean,
        open: suspend (host: String, serial: String) -> Unit,
    ) {
        refusal(host, network, inUse)?.let { throw LunaStationFailure(it) }
        join()
        if (!probe(host.host)) throw LunaStationFailure(failure(
            ConnectionFailure.Reason.NotFound, "station.known-host-silent",
            "The camera did not answer at its last address on “${network.ssid}”.",
        ))
        open(host.host, host.serial)
    }

    private fun failure(reason: ConnectionFailure.Reason, code: String, message: String) =
        LunaFailures.failure(reason, code, message, CorePhase.JOINING_NETWORK)
}
