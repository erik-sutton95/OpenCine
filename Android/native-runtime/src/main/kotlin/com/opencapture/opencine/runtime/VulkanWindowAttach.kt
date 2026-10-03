package com.opencapture.opencine.runtime

/** Window detach is a cover/rotation event, not a decoder or native-owner teardown. */
object VulkanWindowAttach {
    const val SURFACE_LIFECYCLE_FOLLOWS_ATTACHMENT_API = 34

    fun shouldCreateSwapchain(width: Int, height: Int): Boolean = width >= 2 && height >= 2

    /**
     * A failed attach is a retry on the next `surfaceChanged`, not a GLES
     * fallback. Falling back unbound MediaCodec from the ImageReader and left
     * the well black while the encoded stream stayed live.
     */
    fun shouldFallbackToGlesOnAttachFailure(): Boolean = false
}
