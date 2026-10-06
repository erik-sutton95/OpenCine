package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.MonitorTransfer

/** Raw colour identifiers stay in the source adapter; the renderer receives a neutral curve. */
val MonitorTransfer.colorMode: Int
    get() = when (this) {
        MonitorTransfer.REC709 -> CameraCommands.COLOR_NORMAL
        MonitorTransfer.HDR -> CameraCommands.COLOR_HDR
        MonitorTransfer.DLOG -> CameraCommands.COLOR_DLOG
        MonitorTransfer.DLOG2 -> CameraCommands.COLOR_DLOG2
        MonitorTransfer.DLOGM -> MonitorTransfer.COLOR_DLOG_M
        MonitorTransfer.ILOG -> MonitorTransfer.ILOG_BRIDGE_ID
        // No DJI colour code: the unknown mode a status carries before the camera reports one.
        MonitorTransfer.SRGB, MonitorTransfer.NLOG, MonitorTransfer.LOG3G10 -> -1
    }

val MonitorTransfer.Companion.COLOR_DLOG_M: Int get() = CameraCommands.COLOR_DLOG_M

/** The monitor's I-Log id, never a camera byte ([CameraCommands.COLOR_ILOG]). */
val MonitorTransfer.Companion.ILOG_BRIDGE_ID: Int get() = CameraCommands.COLOR_ILOG

fun MonitorTransfer.Companion.fromColorMode(code: Int): MonitorTransfer = when (code) {
    CameraCommands.COLOR_HDR -> MonitorTransfer.HDR
    CameraCommands.COLOR_DLOG -> MonitorTransfer.DLOG
    COLOR_DLOG_M -> MonitorTransfer.DLOGM
    CameraCommands.COLOR_DLOG2 -> MonitorTransfer.DLOG2
    ILOG_BRIDGE_ID -> MonitorTransfer.ILOG
    else -> MonitorTransfer.REC709
}

fun MonitorTransfer.Companion.inferred(minByte: Int, maxByte: Int, fallback: MonitorTransfer): MonitorTransfer {
    if (fallback != MonitorTransfer.REC709) return fallback
    if (minByte in 12..22 && maxByte in 180..252) return MonitorTransfer.DLOG2
    if (minByte in 20..30 && maxByte in 160..240) return MonitorTransfer.DLOG
    return fallback
}

/** The curve the monitor reads this status through: its [CameraStatus.monitorColorMode], decoded. */
val CameraStatus.monitorTransfer: MonitorTransfer
    get() = MonitorTransfer.fromColorMode(monitorColorMode)
