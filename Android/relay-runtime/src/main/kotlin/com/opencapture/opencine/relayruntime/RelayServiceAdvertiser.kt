package com.opencapture.opencine.relayruntime

import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import com.opencapture.opencine.relay.RelayWireProfile

/** Only the framework NSD registration handle lives here; callers supply immutable wire facts. */
public class RelayServiceAdvertiser(private val manager: NsdManager) {
    private val owner = RelayAdvertisementOwner { value, onRegistered ->
        val info = NsdServiceInfo().apply {
            serviceName = value.name
            serviceType = value.serviceType
            setPort(value.port)
            for ((key, attribute) in value.attributes) setAttribute(key, attribute)
        }
        val registration = Registration(manager, onRegistered)
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
        registration
    }
    public fun register(
        profile: RelayWireProfile, name: String, port: Int,
        servedCameraHost: String?, watchable: Boolean = true,
    ): Unit {
        val attributes = buildMap {
            servedCameraHost?.takeIf(String::isNotBlank)?.let { put(profile.servedCameraTXTKey, it) }
            if (!watchable) put(profile.watchableTXTKey, "0")
        }
        owner.register(RelayServiceAdvertisement(name, profile.serviceType, port, attributes))
    }
    public fun unregister(): Unit { owner.stop() }
    private class Registration(
        private val manager: NsdManager, private val onRegistered: () -> Unit,
    ) : NsdManager.RegistrationListener, RelayServiceRegistration {
        override fun stop() {
            try { manager.unregisterService(this) } catch (_: IllegalArgumentException) {
                // A stop can precede registration. A late registered callback withdraws again.
            }
        }
        override fun onServiceRegistered(serviceInfo: NsdServiceInfo) { onRegistered() }
        override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
        override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
        override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
    }
}
