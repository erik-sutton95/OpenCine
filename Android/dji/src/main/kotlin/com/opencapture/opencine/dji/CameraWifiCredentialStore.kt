package com.opencapture.opencine.dji

import android.content.Context
import com.opencapture.opencine.platform.CameraWifiStorageConfiguration
import kotlinx.coroutines.sync.Mutex

/**
 * Existing saved credential namespace; passwords never enter saved-camera JSON. Reads and writes
 * go through [com.opencapture.opencine.platform.withCredentialIO] with [ioTransaction].
 */
class CameraWifiCredentialStore(context: Context) {
    internal val ioTransaction: Mutex = Mutex()
    private val delegate = com.opencapture.opencine.platform.CameraWifiCredentialStore(
        context,
        CameraWifiStorageConfiguration(
            preferencesName = "openpocketcine.camera-wifi",
            keyAlias = "openpocketcine.camera-wifi",
            ssidKeySuffix = ".ssid",
            passwordKeySuffix = ".password",
            ssidIndexPrefix = "ssid:",
        ),
    )

    fun load(cameraId: String): Pair<String, String>? = delegate.load(cameraId)
    fun passphrase(ssid: String): String? = delegate.passphrase(ssid)
    fun save(cameraId: String, ssid: String, password: String) = delegate.save(cameraId, ssid, password)
    fun remove(cameraId: String) = delegate.remove(cameraId)
}
