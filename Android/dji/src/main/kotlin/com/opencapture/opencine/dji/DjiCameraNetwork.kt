package com.opencapture.opencine.dji

import com.opencapture.opencine.media.PrivacyRedactor

/**
 * DJI camera access points in diagnostics: a DJI app keeps them readable and redacts every other
 * SSID. The neutral redactor redacts all of them. Swift twin: `DJICameraNetwork`.
 */
object DjiCameraNetwork {
    /** The DJI family names a camera's access point carries. */
    fun isAccessPoint(ssid: String): Boolean {
        val n = ssid.lowercase().replace("\"", "").replace("'", "")
        return listOf("osmo", "pocket", "nano", "muse", "atto", "xtra", "edge").any { n.contains(it) }
    }

    /** The host redaction of a DJI app. */
    fun redact(text: String): String = PrivacyRedactor.redact(text, ::isAccessPoint)
}
