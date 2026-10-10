package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.QuickTimeKeys
import java.io.File

/**
 * Swift `ClipColorProfile`. Shot color is QuickTime Keys `com.dji.camera.ColorGammaSxS` (`nclx` is
 * Rec.709 even for D-Log2); Media's `QuickTimeKeys` reads the file. The MP4 window readers are dji
 * extensions (byte code stays out of the vocabulary). -1 is no shot color, as the apps' caches store it.
 */
object ClipColorProfile {
    const val GAMMA_KEY = "com.dji.camera.ColorGammaSxS"

    fun colorModeFromGamma(gamma: String): Int =
        when (gamma.trim()) {
            "Rec.709" -> CameraCommands.COLOR_NORMAL
            "Rec.2100 HLG" -> CameraCommands.COLOR_HDR
            "D-Log" -> CameraCommands.COLOR_DLOG
            "D-Log2" -> CameraCommands.COLOR_DLOG2
            "D-Log M", "D-LogM", "DLogM" -> CameraCommands.COLOR_DLOG_M
            else -> -1
        }

    /** LRF / XRF / LRV Keys are Rec.709 even on D-Log2; never use them for Auto. */
    fun shotColorFromFile(file: File, path: String): Int {
        if (MediaHTTP.isProxyPath(path)) return -1
        return colorModeFromFile(file)
    }

    fun colorModeFromFile(file: File): Int =
        try {
            val window = QuickTimeKeys.tail(file) ?: return -1
            QuickTimeKeys.keys(window, GAMMA_KEY)[GAMMA_KEY]?.let(::colorModeFromGamma) ?: -1
        } catch (_: Exception) {
            -1
        }
}
