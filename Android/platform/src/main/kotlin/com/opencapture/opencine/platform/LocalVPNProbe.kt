package com.opencapture.opencine.platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/** Whether a local VPN tunnel is up (core `LocalVPNFilter` owns the copy and when to hint). */
object LocalVPNProbe {
    fun isActive(context: Context): Boolean {
        val connectivity =
            context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager ?: return false
        return isActive(connectivity)
    }

    @Suppress("DEPRECATION")
    fun isActive(connectivity: ConnectivityManager): Boolean =
        connectivity.allNetworks.any { network ->
            connectivity.getNetworkCapabilities(network)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }

    @Volatile private var loggedActive = false

    /** Hands [log] the notice once per process, the first time a tunnel is seen. */
    fun noteIfActive(context: Context, log: (String) -> Unit) {
        if (!isActive(context) || loggedActive) return
        loggedActive = true
        log("vpn: local VPN or ad blocker active — can drop UDP live view")
    }
}
