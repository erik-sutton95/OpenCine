package com.opencapture.opencine.dji

/**
 * Where the DJI code journals (BLE scan and initialization, datalink, local VPN warnings). The
 * app points [sink] at its diagnostics at startup; while unset, entries are dropped.
 */
object DjiLog {
    @Volatile
    var sink: ((level: String, category: String, code: String, message: String) -> Unit)? = null

    fun log(level: String, category: String, code: String, message: String) {
        sink?.invoke(level, category, code, message)
    }
}
