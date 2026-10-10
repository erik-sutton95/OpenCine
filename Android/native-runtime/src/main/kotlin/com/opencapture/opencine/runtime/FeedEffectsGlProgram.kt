package com.opencapture.opencine.runtime

import android.graphics.Bitmap
import android.opengl.GLES20
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.feedEffectsCubeAtlas
import java.nio.ByteBuffer

private const val FEED_EFFECTS_VERTEX_SHADER = "shaders/playback_feed_vertex_es2.glsl"
private const val FEED_EFFECTS_FRAGMENT_SHADER = "shaders/playback_feed_fragment_es2.glsl"
private const val PEAKING_BLUR_FRAGMENT_SHADER = "shaders/peaking_blur_fragment_es2.glsl"
private const val PEAKING_MASK_FRAGMENT_SHADER = "shaders/peaking_mask_fragment_es2.glsl"

/**
 * GLES2 adapter for the live-monitor look. Callers own the 2D input texture,
 * output framebuffer, viewport, and GL thread.
 *
 * Peaking is three passes: vertical re-blur, detector mask, then composite.
 * [draw] saves and restores the caller's framebuffer around the offscreen work.
 */
class FeedEffectsGlProgram(
    private val gl: NativeGlBackend,
    private var plan: FeedEffectsRenderPlan,
    flipInputVertically: Boolean = false,
    private val reconstructToDisplay: (Float, Float, Float, Float) -> Boolean = { _, _, _, _ -> false },
) {
    private val program = gl.createProgram(FEED_EFFECTS_VERTEX_SHADER, FEED_EFFECTS_FRAGMENT_SHADER)
    private val lutCube = uploadCube(plan.lutCube)
    private val limitsPaintCube = uploadCube(plan.falseColorPaint)
    private val limitsWeightCube = uploadCube(plan.falseColorWeight)
    private val blurProgram =
        if (plan.peaking) {
            gl.createProgram(FEED_EFFECTS_VERTEX_SHADER, PEAKING_BLUR_FRAGMENT_SHADER)
        } else {
            null
        }
    private val maskProgram =
        if (plan.peaking) {
            gl.createProgram(FEED_EFFECTS_VERTEX_SHADER, PEAKING_MASK_FRAGMENT_SHADER)
        } else {
            null
        }
    private var blurTarget: PeakingMaskTarget? = null
    private var maskTarget: PeakingMaskTarget? = null
    private var maskStubTexture = 0

    init {
        program.setBufferAttribute(
            "aFramePosition",
            gl.normalizedCoordinateBounds(),
            gl.homogeneousCoordinateVectorSize,
        )
        program.setFloatsUniform("uFlipInputY", flag(flipInputVertically))
        bindStaticUniforms(plan)
        blurProgram?.let { blur ->
            blur.setBufferAttribute(
                "aFramePosition",
                gl.normalizedCoordinateBounds(),
                gl.homogeneousCoordinateVectorSize,
            )
            blur.setFloatsUniform("uFlipInputY", flag(flipInputVertically))
        }
        maskProgram?.let { mask ->
            mask.setBufferAttribute(
                "aFramePosition",
                gl.normalizedCoordinateBounds(),
                gl.homogeneousCoordinateVectorSize,
            )
            mask.setFloatsUniform("uFlipInputY", flag(flipInputVertically))
        }
        bindMaskUniforms()
    }

    /**
     * Keeps the compiled programs and uploaded cubes when [next] differs only in scalars
     * or scope policy (ISO, zebra levels, colours, scopes). False means the caller rebuilds.
     */
    fun adopt(next: FeedEffectsRenderPlan): Boolean {
        if (!plan.sharesGlResources(next)) return false
        plan = next
        bindMaskUniforms()
        return true
    }

    private fun bindMaskUniforms() {
        maskProgram?.setFloatsUniform("uPeakingRatioThreshold", floatArrayOf(plan.peakingRatioThreshold))
        maskProgram?.setFloatsUniform("uPeakingNoiseGate", floatArrayOf(plan.peakingNoiseGate))
    }

    /**
     * [look] true cubes at this raster (iOS bakeSize). False is present of that
     * bake - bilinear, or Catmull-Rom when Fast magnifies. Evaluating the source LUT after
     * reconstruction blotches high-contrast values.
     */
    fun draw(
        inputTexture: Int,
        sourceWidth: Float,
        sourceHeight: Float,
        displayWidth: Float,
        displayHeight: Float,
        mirrored: Boolean = false,
        look: Boolean = true,
        upscale: Boolean = !look,
        /** A one-pass look reconstructs the magnified raster before grading (Bitmap surface). */
        onePassUpscale: Boolean = false,
        /** Vertical presentation flip, independent from the source texture's input convention. */
        mirroredVertical: Boolean = false,
    ) {
        val mask =
            if (look && plan.peaking) {
                renderPeakingMask(inputTexture, sourceWidth, sourceHeight)
            } else {
                maskStub()
            }
        program.use()
        program.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
        program.setSamplerTexIdUniform("uPeakingMask", mask, 4)
        program.setSamplerTexIdUniform("uLut", lutCube.textureId, 1)
        program.setSamplerTexIdUniform("uLimitsPaintCube", limitsPaintCube.textureId, 2)
        program.setSamplerTexIdUniform("uLimitsWeightCube", limitsWeightCube.textureId, 3)
        program.setFloatsUniform(
            "uSourceSize",
            floatArrayOf(sourceWidth.coerceAtLeast(1f), sourceHeight.coerceAtLeast(1f)),
        )
        program.setFloatsUniform(
            "uDisplaySize",
            floatArrayOf(displayWidth.coerceAtLeast(1f), displayHeight.coerceAtLeast(1f)),
        )
        if (look) {
            bindStaticUniforms(plan)
            program.setFloatsUniform("uFeedUpscale", flag(false))
            program.setFloatsUniform("uFeedOnePassUpscale", flag(onePassUpscale))
            program.setFloatsUniform("uMirror", flag(mirrored))
            program.setFloatsUniform("uMirrorVertical", flag(mirroredVertical))
        } else {
            program.setFloatsUniform("uLutSize", floatArrayOf(0f))
            program.setFloatsUniform("uLimitsOn", flag(false))
            program.setFloatsUniform("uPeakingOn", flag(false))
            program.setFloatsUniform("uZebraHighlightOn", flag(false))
            program.setFloatsUniform("uZebraMidtoneOn", flag(false))
            program.setFloatsUniform("uSplitOn", flag(false))
            program.setFloatsUniform("uMirror", flag(false))
            program.setFloatsUniform("uMirrorVertical", flag(false))
            program.setFloatsUniform("uFeedOnePassUpscale", flag(false))
            program.setFloatsUniform(
                "uFeedUpscale",
                flag(
                    upscale &&
                        reconstructToDisplay(
                            sourceWidth,
                            sourceHeight,
                            displayWidth,
                            displayHeight,
                        ),
                ),
            )
        }
        program.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        gl.checkError()
    }

    private fun renderPeakingMask(
        inputTexture: Int,
        sourceWidth: Float,
        sourceHeight: Float,
    ): Int {
        val blur = blurProgram ?: return maskStub()
        val mask = maskProgram ?: return maskStub()
        val width = sourceWidth.toInt().coerceAtLeast(1)
        val height = sourceHeight.toInt().coerceAtLeast(1)
        val sourceSize = floatArrayOf(width.toFloat(), height.toFloat())

        val previousFramebuffer = IntArray(1)
        GLES20.glGetIntegerv(GLES20.GL_FRAMEBUFFER_BINDING, previousFramebuffer, 0)
        val previousViewport = IntArray(4)
        GLES20.glGetIntegerv(GLES20.GL_VIEWPORT, previousViewport, 0)

        val blurPass = peakingBlurTarget(width, height)
        val maskPass = peakingMaskTarget(width, height)

        gl.focusFramebuffer(blurPass.framebufferId, width, height)
        blur.use()
        blur.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
        blur.setFloatsUniform("uSourceSize", sourceSize)
        blur.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        gl.checkError()

        gl.focusFramebuffer(maskPass.framebufferId, width, height)
        mask.use()
        mask.setSamplerTexIdUniform("uTexSampler", inputTexture, 0)
        mask.setSamplerTexIdUniform("uPeakingBlur", blurPass.textureId, 1)
        mask.setFloatsUniform("uSourceSize", sourceSize)
        mask.bindAttributesAndUniforms()
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        gl.checkError()

        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, previousFramebuffer[0])
        GLES20.glViewport(
            previousViewport[0],
            previousViewport[1],
            previousViewport[2],
            previousViewport[3],
        )
        return maskPass.textureId
    }

    private fun maskStub(): Int {
        if (maskStubTexture == 0) maskStubTexture = uploadStubTexture()
        return maskStubTexture
    }

    private fun peakingMaskTarget(width: Int, height: Int): PeakingMaskTarget {
        maskTarget?.let { existing ->
            if (existing.width == width && existing.height == height) return existing
            existing.release()
            maskTarget = null
        }
        return createSourceSizedTarget(width, height).also { maskTarget = it }
    }

    private fun peakingBlurTarget(width: Int, height: Int): PeakingMaskTarget {
        blurTarget?.let { existing ->
            if (existing.width == width && existing.height == height) return existing
            existing.release()
            blurTarget = null
        }
        return createSourceSizedTarget(width, height).also { blurTarget = it }
    }

    private fun createSourceSizedTarget(width: Int, height: Int): PeakingMaskTarget {
        val textureId = gl.createTexture(width, height)
        val framebufferId = gl.createFramebuffer(textureId)
        return PeakingMaskTarget(gl, textureId, framebufferId, width, height)
    }

    fun release() {
        program.delete()
        blurProgram?.delete()
        maskProgram?.delete()
        blurTarget?.release()
        blurTarget = null
        maskTarget?.release()
        maskTarget = null
        if (maskStubTexture != 0) {
            gl.deleteTexture(maskStubTexture)
            maskStubTexture = 0
        }
        gl.deleteTexture(lutCube.textureId)
        gl.deleteTexture(limitsPaintCube.textureId)
        gl.deleteTexture(limitsWeightCube.textureId)
    }

    private fun bindStaticUniforms(plan: FeedEffectsRenderPlan) {
        program.setFloatsUniform("uLutSize", floatArrayOf(lutCube.cubeSize.toFloat()))
        program.setFloatsUniform("uSplitOn", flag(plan.splitComparison))
        program.setFloatsUniform("uSplitVertical", flag(plan.splitVertical))
        program.setFloatsUniform("uLimitsPaintSize", floatArrayOf(limitsPaintCube.cubeSize.toFloat()))
        program.setFloatsUniform("uLimitsWeightSize", floatArrayOf(limitsWeightCube.cubeSize.toFloat()))
        program.setFloatsUniform("uLimitsOn", flag(plan.falseColorOn))
        program.setFloatsUniform("uPeakingOn", flag(plan.peaking))
        program.setFloatsUniform("uPeakingColor", plan.peakingColor)
        program.setFloatsUniform("uZebraMaximumComponent", flag(plan.zebraMaskPolicy.highlightMeasure == com.opencapture.opencine.media.MonitorZebraMaskPolicy.HighlightMeasure.MAXIMUM_COMPONENT))
        program.setFloatsUniform("uZebraRampBias", floatArrayOf(plan.zebraMaskPolicy.rampBias.toFloat()))
        program.setFloatsUniform("uZebraHighlightOn", flag(plan.zebraHighlightOn))
        program.setFloatsUniform("uZebraHighlight", floatArrayOf(plan.zebraHighlightCode))
        program.setFloatsUniform("uZebraHighlightColor", plan.zebraHighlightColor)
        program.setFloatsUniform("uZebraMidtoneOn", flag(plan.zebraMidtoneOn))
        program.setFloatsUniform("uZebraMidtone", floatArrayOf(plan.zebraMidtoneCode))
        program.setFloatsUniform("uZebraMidtoneHalf", floatArrayOf(plan.zebraMidtoneHalf))
        program.setFloatsUniform("uZebraMidtoneColor", plan.zebraMidtoneColor)
    }

    private fun uploadCube(cube: MonitorLUTCube?): UploadedFeedEffectsCube {
        if (cube == null) {
            val stub = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
            return UploadedFeedEffectsCube(upload(stub), 0)
        }
        val atlas = feedEffectsCubeAtlas(cube)
        val bitmap = Bitmap.createBitmap(atlas.width, atlas.height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(atlas.rgba))
        return UploadedFeedEffectsCube(upload(bitmap), atlas.cubeSize)
    }

    private fun uploadStubTexture(): Int {
        val stub = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        return upload(stub)
    }

    private fun upload(bitmap: Bitmap): Int =
        try {
            gl.createTexture(bitmap)
        } finally {
            bitmap.recycle()
        }

    private fun flag(enabled: Boolean): FloatArray = floatArrayOf(if (enabled) 1f else 0f)
}

private data class UploadedFeedEffectsCube(
    val textureId: Int,
    val cubeSize: Int,
)

private data class PeakingMaskTarget(
    val gl: NativeGlBackend,
    val textureId: Int,
    val framebufferId: Int,
    val width: Int,
    val height: Int,
) {
    fun release() {
        gl.deleteFramebuffer(framebufferId)
        gl.deleteTexture(textureId)
    }
}
