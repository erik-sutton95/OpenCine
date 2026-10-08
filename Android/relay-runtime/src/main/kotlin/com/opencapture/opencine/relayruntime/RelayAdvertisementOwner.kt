package com.opencapture.opencine.relayruntime

/** Stable advertisement facts are copied before entering the asynchronous platform port. */
public class RelayServiceAdvertisement(
    public val name: String, public val serviceType: String, public val port: Int,
    attributes: Map<String, String>,
) {
    public val attributes: Map<String, String> = attributes.toMap()
}
public interface RelayServiceRegistration { public fun stop(): Unit }
public fun interface RelayServiceRegistrationPort {
    public fun register(value: RelayServiceAdvertisement, onRegistered: () -> Unit): RelayServiceRegistration
}

/** Stop before framework registration is legal; a late completion withdraws its own handle. */
public class RelayAdvertisementOwner(private val port: RelayServiceRegistrationPort) {
    private class Window { var handle: RelayServiceRegistration? = null }
    private var window: Window? = null
    @Synchronized public fun register(value: RelayServiceAdvertisement): Unit {
        stop()
        val started = Window()
        window = started
        val handle = port.register(value) {
            synchronized(this) { if (window !== started) started.handle?.stop() }
        }
        started.handle = handle
        if (window !== started) handle.stop()
    }
    @Synchronized public fun stop(): Unit {
        val retired = window
        window = null
        retired?.handle?.stop()
    }
}
