package com.opencapture.opencine.platform

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Handler
import android.os.Looper
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.Socket
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * The operator's shared IPv4 path (moved from `:dji` so every camera integration and app shares
 * it; `com.opencapture.opencine.dji.SharedWiFi` keeps its API on top). iOS `SharedWiFiPath` plus the host join that
 * `NEHotspotConfiguration` performs there. Local Wi-Fi sockets are bound to the
 * Wi-Fi [Network]; Android otherwise routes LAN traffic over cellular when the
 * Wi-Fi has no internet. The phone's own hotspot uses its tethering interface.
 */
open class SharedWiFiPath(
    context: Context,
    /** Diagnostics: `(level, code, message)`; never a password. */
    private val log: (String, String, String) -> Unit = { _, _, _ -> },
) {
    private val app = context.applicationContext
    private val connectivity = app.getSystemService(ConnectivityManager::class.java)
    private val wifi = app.getSystemService(WifiManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private var requested: Network? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var processBound = false
    @Volatile var hotspot = false

    /** Current station SSID, or null when unknown (location off or not on Wi-Fi). */
    @Suppress("DEPRECATION")
    fun currentSsid(): String? {
        val raw = runCatching { wifi?.connectionInfo?.ssid }.getOrNull() ?: return null
        val name = raw.removeSurrounding("\"")
        return name.takeIf { it.isNotEmpty() && it != "<unknown ssid>" }
    }

    fun address(hotspot: Boolean = this.hotspot): String? = ipv4(hotspot)?.first

    fun netmask(hotspot: Boolean = this.hotspot): String? = ipv4(hotspot)?.second?.let(::mask)

    /** Local Wi-Fi only; the hosting phone never joins its own hotspot. */
    suspend fun join(ssid: String, password: String): Boolean {
        if (hotspot) return true
        if (currentSsid() == ssid && address(false) != null) return true
        release()
        val builder = WifiNetworkSpecifier.Builder().setSsid(ssid)
        if (password.isNotEmpty()) builder.setWpa2Passphrase(password)
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(builder.build())
            .build()
        log("info", "wifi", "request shared Wi-Fi")
        val network = withTimeoutOrNull(JOIN_TIMEOUT_MS + 5_000L) {
            suspendCancellableCoroutine<Network?> { continuation ->
                val networkCallback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        synchronized(lock) { requested = network }
                        if (continuation.isActive) continuation.resume(network)
                    }

                    override fun onUnavailable() {
                        if (continuation.isActive) continuation.resume(null)
                    }

                    override fun onLost(network: Network) {
                        synchronized(lock) { if (requested == network) requested = null }
                    }
                }
                synchronized(lock) { callback = networkCallback }
                runCatching {
                    connectivity?.requestNetwork(request, networkCallback, main, JOIN_TIMEOUT_MS)
                }.onFailure { if (continuation.isActive) continuation.resume(null) }
                continuation.invokeOnCancellation { release() }
            }
        }
        if (network == null) {
            release()
            return false
        }
        repeat(60) {
            if (address(false) != null) return true
            delay(200)
        }
        return address(false) != null
    }

    fun release() {
        val (registered, unbind) = synchronized(lock) {
            val current = callback
            val bound = processBound
            callback = null
            requested = null
            processBound = false
            current to bound
        }
        if (unbind) runCatching { connectivity?.bindProcessToNetwork(null) }
        registered?.let { runCatching { connectivity?.unregisterNetworkCallback(it) } }
    }

    /**
     * Routes the whole process over this path's Wi-Fi until [release], so traffic that cannot bind
     * its own sockets (an HTTP client) reaches hosts on it even when the Wi-Fi has no internet.
     * Never for a hotspot: its clients are reached through the local tethering route.
     */
    fun bindProcess(): Boolean {
        if (hotspot) return false
        val network = wifiNetwork() ?: return false
        val bound = runCatching { connectivity?.bindProcessToNetwork(network) == true }.getOrDefault(false)
        if (bound) synchronized(lock) { processBound = true }
        return bound
    }

    open fun bindSocket(socket: DatagramSocket) {
        if (!hotspot) wifiNetwork()?.let { runCatching { it.bindSocket(socket) } }
    }

    open fun bindSocket(socket: Socket) {
        if (!hotspot) wifiNetwork()?.let { runCatching { it.bindSocket(socket) } }
    }

    open fun isProcessBound(): Boolean = address() != null

    open fun cameraLocalIPv4(): String? = address()

    /** The Wi-Fi [Network] this path uses: the one [join] requested, else the connected Wi-Fi. */
    fun network(): Network? = wifiNetwork()

    /** Address and prefix length on the Wi-Fi ([hotspot] false) or this phone's hotspot. */
    fun addressWithPrefix(hotspot: Boolean = this.hotspot): Pair<String, Int>? = ipv4(hotspot)

    @Suppress("DEPRECATION")
    private fun wifiNetwork(): Network? {
        synchronized(lock) { requested }?.let { return it }
        val manager = connectivity ?: return null
        return manager.allNetworks.firstOrNull { network ->
            val caps = manager.getNetworkCapabilities(network) ?: return@firstOrNull false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                manager.getLinkProperties(network)?.linkAddresses?.any { it.address is Inet4Address } == true
        }
    }

    private fun wifiInterface(): String? =
        wifiNetwork()?.let { connectivity?.getLinkProperties(it)?.interfaceName }

    /** Address and prefix length of the selected path. */
    private fun ipv4(hotspot: Boolean): Pair<String, Int>? {
        if (!hotspot) {
            val network = wifiNetwork() ?: return null
            val link = connectivity?.getLinkProperties(network)?.linkAddresses
                ?.firstOrNull { it.address is Inet4Address } ?: return null
            return link.address.hostAddress?.let { it to link.prefixLength }
        }
        val station = wifiInterface()
        val interfaces = runCatching { NetworkInterface.getNetworkInterfaces()?.toList() }.getOrNull() ?: return null
        // ponytail: tethering interface names are vendor-specific (Samsung swlan0,
        // AOSP ap0/wlan1). Extend the prefix list when a device reports another.
        for (item in interfaces) {
            val name = item.name ?: continue
            if (name == station || !runCatching { item.isUp }.getOrDefault(false)) continue
            if (HOTSPOT_PREFIXES.none { name.startsWith(it) }) continue
            val address = item.interfaceAddresses.firstOrNull { it.address is Inet4Address } ?: continue
            val host = address.address.hostAddress ?: continue
            return host to address.networkPrefixLength.toInt()
        }
        return null
    }

    companion object {
        private const val JOIN_TIMEOUT_MS = 45_000
        private val HOTSPOT_PREFIXES = listOf("swlan", "ap", "softap", "wlan1", "wigig")

        fun mask(prefix: Int): String {
            val bits = if (prefix <= 0) 0L else (0xFFFFFFFFL shl (32 - prefix.coerceAtMost(32))) and 0xFFFFFFFFL
            return listOf(24, 16, 8, 0).joinToString(".") { ((bits shr it) and 0xFF).toString() }
        }

        /** iOS `SharedWiFiPath.validAddress`: unicast IPv4, not loopback. */
        fun validAddress(value: String): Boolean {
            val parts = value.split(".")
            if (parts.size != 4) return false
            val bytes = parts.map { it.toIntOrNull() ?: return false }
            if (bytes.any { it !in 0..255 }) return false
            return bytes[0] in 1..223 && bytes[0] != 127
        }
    }
}

