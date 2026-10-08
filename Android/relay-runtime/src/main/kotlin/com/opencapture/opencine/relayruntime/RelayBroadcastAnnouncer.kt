package com.opencapture.opencine.relayruntime

import android.net.nsd.NsdManager
import com.opencapture.opencine.relay.RelayWireProfile
import java.util.UUID

/** Instance SDK composition; deployed names and encoded presence facts arrive from the host. */
public class RelayBroadcastAnnouncer(
    manager: NsdManager,
    private val profile: RelayWireProfile,
    private val deviceName: String,
    private val presenceLine: (String?, Int) -> ByteArray,
    onPresenceBindFailure: () -> Unit = {},
) : RelayBroadcastAnnouncement {
    private val lock: Any = Any()
    private var window: UUID = UUID.randomUUID()
    private val advertisement: RelayServiceAdvertiser = RelayServiceAdvertiser(manager)
    private val presence: RelayPassiveListener? = profile.presenceTcpPort?.let {
        RelayPassiveListener(port = it, onBindFailure = onPresenceBindFailure)
    }
    override fun start(port: Int, servedCameraHost: String?): Unit {
        val source = synchronized(lock) { UUID.randomUUID().also { window = it } }
        advertisement.register(profile, deviceName, port, servedCameraHost)
        if (!synchronized(lock) { window == source }) return
        presence?.update(presenceLine(servedCameraHost, port))
    }
    override fun stop(): Unit {
        synchronized(lock) { window = UUID.randomUUID() }
        advertisement.unregister()
        presence?.stop()
    }
}
