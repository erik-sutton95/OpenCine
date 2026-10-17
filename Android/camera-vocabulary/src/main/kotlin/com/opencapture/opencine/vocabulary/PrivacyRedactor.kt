package com.opencapture.opencine.vocabulary

/**
 * The neutral redactor: every SSID goes. An integration that keeps its camera access points
 * readable supplies that predicate itself (DJI: `DjiCameraNetwork`). Lockstep with Swift
 * `PrivacyRedactor`.
 */
object PrivacyRedactor {
    const val COMPACT_CHARACTER_CAP = 1400

    fun redact(text: String): String =
        com.opencapture.opencine.media.PrivacyRedactor.redact(text)

    fun clampCompact(text: String): String =
        com.opencapture.opencine.media.PrivacyRedactor.clampCompact(text)

    fun isLocalIPv4(ip: String): Boolean =
        com.opencapture.opencine.media.PrivacyRedactor.isLocalIPv4(ip)
}
