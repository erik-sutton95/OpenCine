package com.opencapture.opencine.insta360.luna

/**
 * Station mode: over the encrypted Bluetooth session the camera leaves its own access point and
 * joins a router or a phone hotspot (Swift `LunaStation.swift`, same evidence and byte shapes).
 * Firmware 1.1.15, 2026-10-01 router-join take: SET_WIFI_MODE 147, PHONE_INFO 220,
 * SET_WIFI_CONNECTION_INFO 112, the unencrypted result notification 8232, then SET_AVAILABLE_WIFI
 * 215, every request encrypted and answered 200; the camera then served control, live preview
 * (H.264, where its own access point sends HEVC) and HTTP on its router address.
 */
object LunaStationWire {
    const val SET_WIFI_CONNECTION_INFO = 112
    const val SET_WIFI_MODE = 147
    const val SET_AVAILABLE_WIFI = 215
    const val PHONE_INFO = 220
    /** The join result notification (`CAMERA_NOTIFICATION_WIFI_STATUS`). */
    const val JOIN_RESULT = 8232
    /** `CAMERA_NOTIFICATION_CAM_WIFI_START`: the camera's Wi-Fi (re)started, as after a role switch. */
    const val WIFI_STARTED = 8215
    /** Reply `INS_ERRORCODE_WIFI_BUSY_SWITCHING`: wait for [WIFI_STARTED], then ask again. */
    const val BUSY_SWITCHING = 505

    /** The camera's Wi-Fi role (`WifiMode`). */
    enum class Mode(val raw: Long) { ACCESS_POINT(0), STATION(1) }

    /** The phone platform `PhoneInfo` names (`PhoneType`). */
    enum class Platform(val raw: Long) { IOS(1), ANDROID(2) }

    /**
     * `SetWifiMode { place_holder = 1, wifi_mode, country_code }`. The region is the camera's own
     * ([countryCode]); anything but a two-letter code is left out, as the official app does with an
     * empty one. proto3 leaves the default access point mode out.
     */
    fun wifiMode(mode: Mode, countryCode: String?): ByteArray {
        var body = LunaWire.integer(1, 1)
        if (mode != Mode.ACCESS_POINT) body += LunaWire.integer(2, mode.raw)
        if (countryCode != null && countryCode.length == 2 && countryCode.all { it.code < 128 && it.isLetter() }) {
            body += LunaWire.blob(3, countryCode.toByteArray())
        }
        return body
    }

    /** `PhoneInfo { device_type, manufacturer, model, os_version }`; empty strings are left out. */
    fun phoneInfo(platform: Platform, manufacturer: String, model: String, osVersion: String): ByteArray {
        var body = LunaWire.integer(1, platform.raw)
        for ((field, text) in listOf(2 to manufacturer, 3 to model, 4 to osVersion)) {
            if (text.isNotEmpty()) body += LunaWire.blob(field, text.toByteArray().take(64).toByteArray())
        }
        return body
    }

    /**
     * Whether the camera can be asked to join this network: a 1 to 32 byte name and an open network
     * or a WPA2 passphrase of 8 to 63 bytes, without NUL.
     */
    fun accepts(ssid: String, password: String): Boolean {
        val name = ssid.toByteArray()
        val secret = password.toByteArray()
        return name.size in 1..32 && 0.toByte() !in name &&
            (secret.isEmpty() || secret.size in 8..63) && 0.toByte() !in secret
    }

    /** `SetWifiConnectionInfo { WifiConnectionInfo { ssid, password } }`: join this network (112). */
    fun join(ssid: String, password: String): ByteArray = info(ssid, password)

    /** `SetAvailableWifi { WifiConnectionInfo { ssid, password } }`, sent after a successful join (215). */
    fun remember(ssid: String, password: String): ByteArray = info(ssid, password)

    private fun info(ssid: String, password: String): ByteArray {
        require(accepts(ssid, password)) { "The camera cannot join this network" }
        var info = LunaWire.blob(1, ssid.toByteArray())
        if (password.isNotEmpty()) info += LunaWire.blob(3, password.toByteArray())
        return LunaWire.blob(1, info)
    }

    /** The camera's answer to a station join (notification 8232). Never shows the password it echoes. */
    data class JoinResult(
        val outcome: Outcome,
        val ssid: String?,
        val address: String?,
        /** The password the camera echoes with the network; only compared. */
        internal val echoedPassword: String? = null,
    ) {
        sealed interface Outcome {
            data object Joined : Outcome
            /** `PASSWORD_ERROR`. */
            data object WrongPassword : Outcome
            /** `NO_SCAN_RESULT`: the camera cannot see the network. */
            data object NetworkNotFound : Outcome
            /** Any other `WifiConnectionResult` value. */
            data class Failed(val code: Long) : Outcome {
                /**
                 * `TIMEOUT` 1, `ERROR_CONNECT_FAILED` 2 and `UNABLE_ASSIGN_IP` 4: the network may
                 * take the camera on a second try (the official app restarts the join for these).
                 */
                val transient: Boolean get() = code in setOf(1L, 2L, 4L)
            }
        }

        /**
         * Whether this result answers a join to [ssid] with [password]. The camera echoes the
         * network it tried (firmware 1.1.15: name and password), so a late result for an earlier
         * join, such as one sent without a password, is told apart. A result without the network
         * answers any join.
         */
        fun answers(ssid: String, password: String): Boolean {
            val reported = this.ssid ?: return true
            return reported == ssid && (echoedPassword ?: "") == password
        }

        override fun toString(): String = "JoinResult($outcome, address: $address)"
    }

    /** Notification 8232's body: the result (field 1, proto3 default success) and the network (ssid 1, password 3, ip_addr 4). */
    fun joinResult(body: ByteArray): JoinResult {
        val code = LunaWire.number(body, 1)
        val outcome = when (code) {
            // SUCCESS 0 and CONNECT_SUCCESS 5.
            0L, 5L -> JoinResult.Outcome.Joined
            3L -> JoinResult.Outcome.WrongPassword
            6L -> JoinResult.Outcome.NetworkNotFound
            else -> JoinResult.Outcome.Failed(code)
        }
        val network = LunaWire.fields(body).lastOrNull { it.number == 2 && it.wire == 2 }?.bytes
        return JoinResult(
            outcome,
            network?.let { LunaWire.text(it, 1) }?.takeIf { it.isNotEmpty() },
            network?.let { LunaWire.text(it, 4) }?.takeIf { it.isNotEmpty() },
            network?.let { LunaWire.text(it, 3) },
        )
    }

    /**
     * The camera's Wi-Fi region from the credential read's reply (option 37 `WifiChannelList`,
     * field 1 `country_code`), or `null` when the reply has none.
     */
    fun countryCode(reply: ByteArray): String? {
        val options = LunaWire.bytes(reply, 2)
        val list = LunaWire.fields(options).lastOrNull { it.number == 37 && it.wire == 2 }?.bytes ?: return null
        return LunaWire.text(list, 1).takeIf { it.isNotEmpty() }?.uppercase()
    }

    /**
     * The hosts to search on this phone's network, nearest first: the whole subnet when it is a /24
     * or smaller (a hotspot is often a /28 or /24), otherwise the phone's own /24. Never the phone
     * itself, the network or the broadcast address. [prefixLength] is the interface's prefix.
     */
    fun candidates(address: String, prefixLength: Int): List<String> {
        val parts = address.split('.').mapNotNull { it.toIntOrNull() }
        if (parts.size != 4 || parts.any { it !in 0..255 } || prefixLength !in 0..32) return emptyList()
        val own = parts.fold(0L) { value, part -> (value shl 8) or part.toLong() }
        val bits = if (prefixLength >= 24) prefixLength else 24
        val mask = if (bits == 0) 0L else (0xFFFFFFFFL shl (32 - bits)) and 0xFFFFFFFFL
        val network = own and mask
        val broadcast = network or (mask.inv() and 0xFFFFFFFFL)
        if (broadcast <= network + 1) return emptyList()
        return (network + 1 until broadcast).filter { it != own }
            .sortedBy { kotlin.math.abs(it - own) }
            .map { "${it shr 24 and 255}.${it shr 16 and 255}.${it shr 8 and 255}.${it and 255}" }
    }
}
