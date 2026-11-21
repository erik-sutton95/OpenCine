package com.opencapture.opencine.core

/**
 * A camera that can encode and publish its own stream to an RTMP address on a shared network,
 * declared by its integration. The phone receives that stream and relays it, so the picture is
 * the camera's own encoding: sharper than a live view, but without the phone's LUT when
 * [takesLut] is false. Swift twin: `CameraStreamPublishing` in `OpenCineCore`.
 */
public data class CameraStreamPublishing(
    /** The picture size the camera publishes. */
    public val width: Int,
    public val height: Int,
    /** The frame rates the camera can publish at, in no particular order. */
    public val frameRates: List<Int>,
    /** The codecs the camera can publish, preferred first. */
    public val codecs: List<Codec>,
    /** Whether the published picture is in a curve a monitor LUT is made for. */
    public val takesLut: Boolean,
    /** Not yet confirmed on hardware: offered only behind the operator's experimental switch. */
    public val experimental: Boolean,
) {
    public enum class Codec { H264, HEVC }

    /** The codec the camera is asked for. */
    public val preferredCodec: Codec? get() = codecs.firstOrNull()

    /**
     * The requested rate when the camera lists it; otherwise the highest listed rate at or below
     * 30, otherwise the lowest listed rate (30 when none is listed).
     */
    public fun frameRate(near: Int?): Int {
        if (near != null && near in frameRates) return near
        return frameRates.filter { it <= 30 }.maxOrNull() ?: frameRates.minOrNull() ?: 30
    }
}
