package com.opencapture.monitorui

/** Live storage has two units; unknown readings do not become zero. */
object MonitorStorageReadoutFormat {
    fun capacity(gigabytes: Long?): String = gigabytes?.takeIf { it >= 0 }?.let { "$it GB" } ?: "\u2014"
    fun remainingMinutes(minutes: Int?): String = minutes?.takeIf { it >= 0 }?.let { "$it Min" } ?: "\u2014 Min"
}
