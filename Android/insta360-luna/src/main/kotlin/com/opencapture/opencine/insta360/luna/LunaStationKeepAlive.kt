package com.opencapture.opencine.insta360.luna

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

/**
 * Keeps a camera on a Wi-Fi or hotspot setup's network (Swift `LunaStationKeepAlive`): firmware
 * v1.2.7 leaves the network about 60 s after each join, so while the control link is open the join
 * is sent again at once and then every [LunaStationWire.KEEP_ALIVE_INTERVAL_MS]
 * ([LunaStationWire.keepAlive]). A failed send is logged and the next one tried on time; the
 * control link's own checks end the connection. The log never shows the password.
 */
internal object LunaStationKeepAlive {
    /** Runs until cancelled. [send] sends one plain request (code, body) over the control link. */
    suspend fun run(
        network: LunaStationNetwork,
        send: suspend (code: Int, body: ByteArray) -> Unit,
        log: (String) -> Unit,
        intervalMs: Long = LunaStationWire.KEEP_ALIVE_INTERVAL_MS,
    ) {
        val body = runCatching { LunaStationWire.keepAlive(network.ssid, network.password) }.getOrNull() ?: return
        var failures = 0
        while (currentCoroutineContext().isActive) {
            try {
                send(LunaStationWire.SET_WIFI_CONNECTION_INFO, body)
                if (failures > 0) log("luna: station keep-alive answered again")
                failures = 0
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                failures += 1
                log("luna: station keep-alive not answered ($failures in a row)")
            }
            delay(intervalMs)
        }
    }
}
