package com.opencapture.opencine.vocabulary

/** Lockstep with Swift `PrivacyRedactor`. */
object PrivacyRedactor {
    const val COMPACT_CHARACTER_CAP = 1400

    fun redact(text: String): String =
        com.opencapture.opencine.media.PrivacyRedactor.redact(text, ::isCameraNetwork)

    fun clampCompact(text: String): String =
        com.opencapture.opencine.media.PrivacyRedactor.clampCompact(text)

    fun isCameraNetwork(raw: String): Boolean {
        val n = raw.lowercase().replace("\"", "").replace("'", "")
        return n.contains("osmo") ||
            n.contains("pocket") ||
            n.contains("nano") ||
            n.contains("muse") ||
            n.contains("atto") ||
            n.contains("xtra") ||
            n.contains("edge")
    }

    fun isLocalIPv4(ip: String): Boolean =
        com.opencapture.opencine.media.PrivacyRedactor.isLocalIPv4(ip)
}
