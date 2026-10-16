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

/** Compatibility adapter for known legacy codes. Unsupported values stay unknown. */
fun MonitorTransfer.Companion.knownFromColorMode(code: Int): MonitorTransfer? = when (code) {
    CameraCommands.COLOR_NORMAL, CameraCommands.COLOR_NORMAL10 -> MonitorTransfer.REC709
    CameraCommands.COLOR_HDR -> MonitorTransfer.HDR
    CameraCommands.COLOR_DLOG -> MonitorTransfer.DLOG
    COLOR_DLOG_M -> MonitorTransfer.DLOGM
    CameraCommands.COLOR_DLOG2 -> MonitorTransfer.DLOG2
    ILOG_BRIDGE_ID -> MonitorTransfer.ILOG
    else -> null
}

/** Retained legacy display policy; new source observations use [knownFromColorMode]. */
fun MonitorTransfer.Companion.fromColorMode(code: Int): MonitorTransfer =
    knownFromColorMode(code) ?: MonitorTransfer.REC709

/** The curve the monitor reads this status through: its [CameraStatus.monitorColorMode], decoded. */
val CameraStatus.monitorTransfer: MonitorTransfer
    get() = MonitorTransfer.fromColorMode(monitorColorMode)

/**
 * The source curve the camera has reported, or null before its first colour report and in Dolby Vision
 * (product ruling 2026-10-16). Curve-reading tools wait for it; photo reads Rec.709.
 */
val CameraStatus.knownMonitorTransfer: MonitorTransfer?
    get() = MonitorTransfer.knownFromColorMode(monitorColorMode)
