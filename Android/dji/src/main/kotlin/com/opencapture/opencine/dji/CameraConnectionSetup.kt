package com.opencapture.opencine.dji

/**
 * How a saved body is reached (iOS `CameraConnectionSetup`, #406). Every record has camera
 * Wi-Fi. Wi-Fi (a router) and Hotspot (this phone's) are OpenZCine-style extra setups that
 * move the camera off its own access point onto that network. [raw] matches iOS.
 */
enum class CameraConnectionSetup(val raw: String, val title: String) {
    CAMERA_WIFI("cameraWiFi", "Camera Wi-Fi"),
    WIFI("wifi", "Wi-Fi"),
    PHONE_HOTSPOT("phoneHotspot", "Hotspot");

    /** The camera leaves its access point (station role) for this setup. */
    val movesCamera: Boolean get() = this != CAMERA_WIFI

    companion object {
        fun fromRaw(raw: String?): CameraConnectionSetup? = entries.firstOrNull { it.raw == raw }
    }
}
