package com.opencapture.opencine.core

/** Camera-reported recording facts. Preview dimensions and transport codec are separate facts. */
public class CameraRecordingFormat private constructor(
    public val dimensions: Dimensions?,
    public val frameRate: Rational?,
    /** Integration-supplied content, never a command or wire byte. */
    public val profile: String?,
    public val codec: String?,
) {
    public companion object {
        public fun measured(dimensions: Dimensions? = null, frameRate: Rational? = null,
            profile: String? = null, codec: String? = null): CameraRecordingFormat = CameraRecordingFormat(
            dimensions, frameRate?.takeIf { it.numerator > 0 },
            profile?.trim()?.takeIf { it.isNotEmpty() }, codec?.trim()?.takeIf { it.isNotEmpty() })
    }

    /** Every construction path keeps the same measured-value normalization. */
    public fun copy(dimensions: Dimensions? = this.dimensions, frameRate: Rational? = this.frameRate,
        profile: String? = this.profile, codec: String? = this.codec): CameraRecordingFormat =
        measured(dimensions, frameRate, profile, codec)

    override fun equals(other: Any?): Boolean = other is CameraRecordingFormat &&
        dimensions == other.dimensions && frameRate == other.frameRate &&
        profile == other.profile && codec == other.codec
    override fun hashCode(): Int = listOf(dimensions, frameRate, profile, codec).hashCode()

    public class Dimensions private constructor(public val width: Int, public val height: Int) {
        public companion object {
            public fun measured(width: Int, height: Int): Dimensions? =
                if (width > 0 && height > 0) Dimensions(width, height) else null
        }
        override fun equals(other: Any?): Boolean = other is Dimensions && width == other.width && height == other.height
        override fun hashCode(): Int = 31 * width + height
    }
}
