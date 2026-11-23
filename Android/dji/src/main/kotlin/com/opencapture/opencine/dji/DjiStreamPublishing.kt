package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraStreamPublishing
import com.opencapture.opencine.vocabulary.CameraModel

/**
 * Which DJI bodies can publish their own 1080p stream to the phone (core [CameraStreamPublishing]).
 * Pocket 4 Pro is proven on hardware (2026-11-21: HEVC over Enhanced RTMP, Rec.709; log is refused
 * in livestream mode, so no LUT). Pocket 4 and Pocket 3 follow the same captures but are unconfirmed,
 * so they are experimental. Osmo Nano has no livestream mode. Swift twin: `DJIStreamPublishing`.
 */
object DjiStreamPublishing {
    fun capability(model: CameraModel): CameraStreamPublishing? {
        val name = model.name.lowercase().replace(" ", "")
        val (codecs, experimental) = when {
            name.contains("pocket4p") ->
                listOf(CameraStreamPublishing.Codec.HEVC, CameraStreamPublishing.Codec.H264) to false
            name.contains("pocket4") ->
                listOf(CameraStreamPublishing.Codec.HEVC, CameraStreamPublishing.Codec.H264) to true
            name.contains("pocket3") || name.contains("muse") -> listOf(CameraStreamPublishing.Codec.H264) to true
            else -> return null
        }
        return CameraStreamPublishing(
            width = 1920, height = 1080, frameRates = listOf(25, 30), codecs = codecs, takesLut = false,
            experimental = experimental,
        )
    }
}
