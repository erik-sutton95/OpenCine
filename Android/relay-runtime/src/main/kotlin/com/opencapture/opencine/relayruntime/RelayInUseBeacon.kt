package com.opencapture.opencine.relayruntime

import android.net.nsd.NsdManager
import com.opencapture.opencine.relay.RelayWireProfile

/** Shared held-camera shield composition; a separate name avoids asynchronous mDNS rename. */
public class RelayInUseBeacon(
    manager: NsdManager,
    private val profile: RelayWireProfile,
    private val advertisementName: String,
    onPresenceBindFailure: () -> Unit = {},
) {
    private val advertiser = RelayServiceAdvertiser(manager)
    private val accepting = RelayPassiveListener(port = 0)
    private val presence = RelayPassiveListener(port = requireNotNull(profile.presenceTcpPort), onBindFailure = onPresenceBindFailure)

    public fun start(servedCameraHost: String, presenceLine: ByteArray): Unit {
        stop()
        if (servedCameraHost.isBlank()) return
        val port = accepting.update(byteArrayOf()) ?: return
        advertiser.register(profile, advertisementName, port, servedCameraHost, watchable = false)
        presence.update(presenceLine)
    }
    public fun stop(): Unit {
        advertiser.unregister()
        presence.stop()
        accepting.stop()
    }
}
