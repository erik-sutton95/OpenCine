package com.opencapture.opencine.dji

import android.content.Context
import com.opencapture.opencine.platform.CameraWifiStorageConfiguration
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex

/** Existing saved credential namespace; passwords never enter saved-camera JSON. */
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

/** Blocking secure storage stays off Main. The caller supplies its captured native connection.
 * Only the existing connection Job and callback token admit entry/publication; no IO is owned here.
 * An entered store transaction keeps its original completion, but an expired caller gets no result.
 */
internal suspend fun <Result> withCredentialIO(
    isCurrent: () -> Boolean,
    dispatcher: kotlinx.coroutines.CoroutineDispatcher = kotlinx.coroutines.Dispatchers.IO,
    transaction: Mutex? = null,
    operation: () -> Result,
): Result {
    val connection = kotlin.coroutines.coroutineContext[kotlinx.coroutines.Job]
    fun requireCurrent() {
        connection?.ensureActive()
        if (!isCurrent()) throw kotlinx.coroutines.CancellationException("camera credential connection changed")
    }
    requireCurrent()
    // Mutex waiting is cooperative: Main yields while the preceding secure transaction finishes.
    transaction?.lock()
    try {
        if (transaction != null) requireCurrent()
        val result = kotlinx.coroutines.withContext(dispatcher) {
            requireCurrent()
            kotlin.coroutines.coroutineContext.ensureActive()
            operation()
        }
        requireCurrent()
        kotlin.coroutines.coroutineContext.ensureActive()
        return result
    } finally {
        transaction?.unlock()
    }
}
