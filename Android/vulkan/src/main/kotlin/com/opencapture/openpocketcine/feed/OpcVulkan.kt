package com.opencapture.openpocketcine.feed

import android.graphics.Bitmap
import android.view.Surface
import android.hardware.HardwareBuffer
import android.util.Log

/**
 * JNI to `libopc_vulkan.so`. One renderer owns the swapchain, the imported
 * decoder AHB, compute histogram, point-list WAVE/PARADE, vectorscope scatter,
 * dual-kawase grab, and SDF glass plates.
 *
 * The package and class name are the JNI binding (`Java_com_opencapture_openpocketcine_feed_OpcVulkan_*`
 * in opc_vulkan.cpp): renaming either needs `RegisterNatives` or renamed exports in the same change.
 */
object OpcVulkan {
    private const val TAG = "OpcVulkan"

    val isAvailable: Boolean by lazy {
        try {
            System.loadLibrary("opc_vulkan")
            nativeProbe()
        } catch (error: Throwable) {
            Log.w(TAG, "vulkan library missing", error)
            false
        }
    }

    @JvmStatic external fun nativeProbe(): Boolean

    @JvmStatic external fun nativeCreate(): Long

    /** Bitmap source/strip-cube pipeline on the same renderer device and WSI owner. */
    @JvmStatic external fun nativeProbeBitmap(): Boolean

    @JvmStatic external fun nativeCreateBitmap(): Long
    @JvmStatic external fun nativeSubmitBitmap(handle: Long, bitmap: Bitmap): Boolean
    @JvmStatic external fun nativeAttachBitmapWindow(handle: Long, surface: Surface): Boolean
    @JvmStatic external fun nativeClearBitmapPlan(handle: Long)
    @JvmStatic external fun nativeConfigureBitmap(
        handle: Long, params: FloatArray,
        lutSize: Int, lut: ByteArray?, paintSize: Int, paint: ByteArray?, weightSize: Int, weight: ByteArray?,
    ): Boolean
    @JvmStatic external fun nativeSetBitmapPaused(handle: Long, paused: Boolean): Boolean
    @JvmStatic external fun nativeClearBitmap(handle: Long)
    @JvmStatic external fun nativeRedrawBitmap(handle: Long): Boolean

    @JvmStatic external fun nativeDestroy(handle: Long)

    @JvmStatic external fun nativeAttachWindow(handle: Long, surface: Surface, w: Int, h: Int): Boolean

    /** Drop the swapchain and ANativeWindow. Safe to call from surfaceDestroyed. */
    @JvmStatic external fun nativeDetachWindow(handle: Long)

    @JvmStatic external fun nativeResize(handle: Long, w: Int, h: Int)

    @JvmStatic external fun nativeSubmit(handle: Long, buffer: HardwareBuffer): Boolean

    /** Re-present last imported frame with current slots (drag/resize, no new HEVC). */
    @JvmStatic external fun nativeRedraw(handle: Long): Boolean

    @JvmStatic external fun nativeSetFeedRect(handle: Long, x: Float, y: Float, w: Float, h: Float, stretchToRect: Boolean)

    @JvmStatic external fun nativeSetUiScale(handle: Long, scale: Float)

    @JvmStatic external fun nativeSetSlots(handle: Long, slots: FloatArray)

    /** Back-to-front GPU slot indices (WAVE=0, PARADE=1, VECTOR=3). */
    @JvmStatic external fun nativeSetStack(handle: Long, order: IntArray)

    @JvmStatic external fun nativeSetPlates(handle: Long, plates: FloatArray)

    @JvmStatic external fun nativeSetIre(
        handle: Long,
        ire: FloatArray,
        lumaR: Float,
        lumaG: Float,
        lumaB: Float,
        stride: Int,
    )

    @JvmStatic
    external fun nativeSetCube(
        handle: Long,
        slot: Int,
        rgba: ByteArray?,
        width: Int,
        height: Int,
        cubeSize: Float,
    )

    @JvmStatic external fun nativeSetFeedFlags(
        handle: Long,
        lutSize: Float,
        limitsOn: Float,
        splitOn: Float,
        splitVertical: Float,
        zebraHiOn: Float,
        zebraHi: Float,
        zebraMidOn: Float,
        zebraMid: Float,
        zebraMidHalf: Float,
        upscale: Float,
        mirror: Float,
        mirrorY: Float,
        peakingOn: Float,
        peakingRatioThreshold: Float,
        peakingNoiseGate: Float,
        peakingR: Float,
        peakingG: Float,
        peakingB: Float,
    )

    @JvmStatic external fun nativeCopyHisto(handle: Long, out: IntArray)

    @JvmStatic external fun nativeSetNeedTap(handle: Long, on: Boolean)

    @JvmStatic external fun nativeSetNeedFace(handle: Long, on: Boolean)

    /** 213×120 RGBA8 tap (PocketScopeSampler.tapSize 1280×720). */
    @JvmStatic external fun nativeCopyTap(handle: Long, out: ByteArray): Boolean

    /** 320×180 identity NV21 (2×2 box of the 640×360 readback) for FaceDetector, not a mirrored swapchain copy. */
    @JvmStatic external fun nativeCopyFace(handle: Long, out: ByteArray): Boolean
}
