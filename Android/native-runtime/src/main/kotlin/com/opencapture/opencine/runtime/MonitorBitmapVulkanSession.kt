package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.Bitmap
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorZebraMaskPolicy
import com.opencapture.openpocketcine.feed.OpcVulkan

/**
 * Native Bitmap picture owner using the existing Vulkan renderer/WSI lifetime.
 * Calls are confined to main, exactly where the Bitmap monitor presents frames.
 * The native renderer owns image upload, graph targets, shaders and synchronization.
 */
class MonitorBitmapVulkanSession(
    private val diagnostic: (String) -> Unit = {},
) {
    private val native = if (OpcVulkan.isAvailable) OpcVulkan.nativeCreateBitmap() else 0L
    private val mounted = NativeRenderLifetime()
    private var view: SurfaceView? = null
    private var closed = false
    private var uploaded: FeedEffectsRenderPlan? = null
    private var uploadedFill = false
    private var uploadedMirror = false
    private var uploadedMirrorVertical = false
    var failed = false
        private set

    init { check(native != 0L) { "Bitmap Vulkan renderer creation failed" } }

    private fun checkThread() {
        check(Looper.myLooper() === Looper.getMainLooper()) { "Bitmap picture owner is main-confined" }
    }

    fun createView(context: Context): SurfaceView {
        checkThread()
        check(!closed)
        if (view != null) OpcVulkan.nativeDetachWindow(native)
        val ticket = mounted.start()
        val created = SurfaceView(context)
        view = created
        created.holder.addCallback(object : SurfaceHolder.Callback {
            private fun current(): Boolean = !closed && mounted.isCurrent(ticket) && view === created
            override fun surfaceCreated(holder: SurfaceHolder) {
                if (!current()) return
                if (!OpcVulkan.nativeAttachBitmapWindow(native, holder.surface)) fail("Bitmap surface attachment failed")
            }
            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                if (current()) {
                    OpcVulkan.nativeResize(native, width, height)
                }
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                if (!current()) return
                OpcVulkan.nativeDetachWindow(native)
            }
        })
        return created
    }

    fun attach(candidate: View) {
        checkThread()
        if (!closed && candidate === view) uploaded = null
    }

    fun detach(candidate: View) {
        checkThread()
        if (closed || candidate !== view) return
        uploaded = null
        OpcVulkan.nativeDetachWindow(native)
    }

    fun updatePlan(plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean, mirroredVertical: Boolean = false) {
        checkThread()
        if (closed || failed) return
        if (plan === uploaded && aspectFill == uploadedFill && mirrored == uploadedMirror && mirroredVertical == uploadedMirrorVertical) return
        uploaded = plan
        uploadedFill = aspectFill
        uploadedMirror = mirrored
        uploadedMirrorVertical = mirroredVertical
        if (plan == null) {
            OpcVulkan.nativeClearBitmapPlan(native)
            return
        }
        val controls = bitmapVulkanUniforms(plan, aspectFill, mirrored, mirroredVertical)
        if (!OpcVulkan.nativeConfigureBitmap(
                native, controls,
                plan?.lutCube?.size ?: 0, plan?.lutCube?.rgba,
                plan?.falseColorPaint?.size ?: 0, plan?.falseColorPaint?.rgba,
                plan?.falseColorWeight?.size ?: 0, plan?.falseColorWeight?.rgba,
            )) fail("Bitmap graph upload failed")
    }

    fun submit(frame: Bitmap) {
        checkThread()
        if (!closed && !failed && !OpcVulkan.nativeSubmitBitmap(native, frame)) fail("Bitmap submit failed")
    }

    fun clearFrame() {
        checkThread()
        if (!closed) OpcVulkan.nativeClearBitmap(native)
    }

    fun resume() {
        checkThread()
        if (closed) return
        uploaded = null
        if (!OpcVulkan.nativeSetBitmapPaused(native, false)) fail("Bitmap resume failed")
    }

    fun pause() {
        checkThread()
        if (!closed) OpcVulkan.nativeSetBitmapPaused(native, true)
    }

    fun close() {
        checkThread()
        if (closed) return
        closed = true
        mounted.stop()
        view = null
        uploaded = null
        OpcVulkan.nativeDestroy(native)
    }

    private fun fail(message: String) {
        failed = true
        diagnostic(message)
    }
}

/** Exact std140 packing for the native typed Bitmap graph. No source interpretation here. */
fun bitmapVulkanUniforms(
    plan: FeedEffectsRenderPlan?, aspectFill: Boolean, mirrored: Boolean,
    mirroredVertical: Boolean = false,
): FloatArray {
    val p = plan ?: FeedEffectsRenderPlan.IDENTITY
    val result = FloatArray(40)
    result[0] = p.lutCube?.size?.toFloat() ?: 0f
    result[1] = if (p.peaking) 1f else 0f
    result[2] = if (p.zebraHighlightOn) 1f else 0f
    result[3] = if (p.zebraMidtoneOn) 1f else 0f
    p.peakingColor.take(3).forEachIndexed { index, value -> result[4 + index] = value }
    p.zebraHighlightColor.take(3).forEachIndexed { index, value -> result[8 + index] = value }
    p.zebraMidtoneColor.take(3).forEachIndexed { index, value -> result[12 + index] = value }
    result[16] = p.peakingRatioThreshold
    result[17] = p.peakingNoiseGate
    result[18] = p.zebraHighlightCode
    result[19] = p.zebraMidtoneCode
    result[20] = if (aspectFill) 1f else 0f
    result[21] = if (p.splitComparison) 1f else 0f
    result[22] = if (p.splitVertical) 1f else 0f
    result[23] = if (mirrored) 1f else 0f
    result[32] = p.falseColorPaint?.size?.toFloat() ?: 0f
    result[33] = p.falseColorWeight?.size?.toFloat() ?: 0f
    result[34] = if (p.falseColorOn) 1f else 0f
    result[36] = if (p.zebraMaskPolicy.highlightMeasure == MonitorZebraMaskPolicy.HighlightMeasure.MAXIMUM_COMPONENT) 1f else 0f
    result[37] = p.zebraMaskPolicy.rampBias.toFloat()
    result[38] = p.zebraMidtoneHalf
    result[39] = if (mirroredVertical) 1f else 0f
    return result
}
