package com.opencapture.opencine.media

/**
 * Immutable GLES input for one live-monitor look.
 *
 * LUT is the displayed grade. FALSE / PEAK / ZEBRA measure encoded camera codes
 * and composite over that look - same order as iOS `LiveMonitorCompositor`.
 */
class FeedEffectsRenderPlan(
    val lutCube: MonitorLUTCube?,
    val falseColorPaint: MonitorLUTCube?,
    val falseColorWeight: MonitorLUTCube?,
    val peaking: Boolean,
    val peakingColor: FloatArray,
    val peakingRatioThreshold: Float,
    val peakingNoiseGate: Float,
    val zebraHighlightOn: Boolean,
    val zebraHighlightCode: Float,
    val zebraHighlightColor: FloatArray,
    val zebraMidtoneOn: Boolean,
    val zebraMidtoneCode: Float,
    val zebraMidtoneHalf: Float,
    val zebraMidtoneColor: FloatArray,
    val splitComparison: Boolean,
    val splitVertical: Boolean,
    val scopeTap: ScopeTapPolicy = ScopeTapPolicy.IDLE,
    val zebraMaskPolicy: MonitorZebraMaskPolicy = MonitorZebraMaskPolicy(),
) {
    val falseColorOn: Boolean
        get() = falseColorPaint != null && falseColorWeight != null

    /** Same look; the present tap also feeds this inspector preview owner. */
    fun withPreviewOwner(owner: Any?): FeedEffectsRenderPlan = FeedEffectsRenderPlan(
        lutCube, falseColorPaint, falseColorWeight, peaking, peakingColor, peakingRatioThreshold,
        peakingNoiseGate, zebraHighlightOn, zebraHighlightCode, zebraHighlightColor, zebraMidtoneOn,
        zebraMidtoneCode, zebraMidtoneHalf, zebraMidtoneColor, splitComparison, splitVertical,
        scopeTap.copy(previewOwner = owner), zebraMaskPolicy,
    )

    /** Same shader set and cube textures; only uniforms or scope policy differ. */
    fun sharesGlResources(other: FeedEffectsRenderPlan): Boolean =
        lutCube === other.lutCube &&
            falseColorPaint === other.falseColorPaint &&
            falseColorWeight === other.falseColorWeight &&
            peaking == other.peaking

    /** LUT / PEAK / FALSE / ZEBRA - grade the player, not a CPU overlay. */
    val hasPlaybackLook: Boolean
        get() =
            lutCube != null ||
                falseColorOn ||
                peaking ||
                zebraHighlightOn ||
                zebraMidtoneOn

    /**
     * Identity for `setVideoEffects`. WAVE / HISTO must not rebuild the
     * Media3 graph - that was the LUT/false-colour "sometimes it doesn't".
     */
    val playbackLookKey: Int
        get() {
            var h = 17
            h = 31 * h + System.identityHashCode(lutCube)
            h = 31 * h + System.identityHashCode(falseColorPaint)
            h = 31 * h + System.identityHashCode(falseColorWeight)
            h = 31 * h + if (peaking) 1 else 0
            h = 31 * h + peakingColor.contentHashCode()
            h = 31 * h + peakingRatioThreshold.hashCode()
            h = 31 * h + peakingNoiseGate.hashCode()
            h = 31 * h + if (zebraHighlightOn) 1 else 0
            h = 31 * h + zebraHighlightCode.hashCode()
            h = 31 * h + zebraHighlightColor.contentHashCode()
            h = 31 * h + if (zebraMidtoneOn) 1 else 0
            h = 31 * h + zebraMidtoneCode.hashCode()
            h = 31 * h + zebraMidtoneHalf.hashCode()
            h = 31 * h + zebraMidtoneColor.contentHashCode()
            h = 31 * h + if (splitComparison) 1 else 0
            h = 31 * h + if (splitVertical) 1 else 0
            // The default preserves existing graph keys; an explicit different mask retires the look.
            if (zebraMaskPolicy != MonitorZebraMaskPolicy()) h = 31 * h + zebraMaskPolicy.hashCode()
            return h
        }

    companion object {
        val IDENTITY =
            FeedEffectsRenderPlan(
                lutCube = null,
                falseColorPaint = null,
                falseColorWeight = null,
                peaking = false,
                peakingColor = floatArrayOf(1f, 72f / 255f, 64f / 255f),
                peakingRatioThreshold = 2.10f,
                peakingNoiseGate = 0.00174f,
                zebraHighlightOn = false,
                zebraHighlightCode = 1f,
                zebraHighlightColor = floatArrayOf(1f, 1f, 1f),
                zebraMidtoneOn = false,
                zebraMidtoneCode = 0.5f,
                zebraMidtoneHalf = 5f / 255f,
                zebraMidtoneColor = floatArrayOf(1f, 0.72f, 0.2f),
                splitComparison = false,
                splitVertical = true,
            )
    }
}
