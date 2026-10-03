package com.opencapture.opencine.runtime

/**
 * Bake→drawable upscaler. Labels match iOS `MonitorGlesUpscaler` raw values.
 *
 * Present of the 720p bake (iOS `bakeSize` then fit). Off is bilinear of
 * Rec.709; Fast is Catmull-Rom of that bake (portable Lanczos analogue).
 * Quality / AI have no GLES equivalent, so they are omitted the same way
 * iOS hides unsupported options. Do not reconstruct log RGB and then cube.
 */
enum class MonitorGlesUpscaler(val label: String) {
    OFF("Off"),
    FAST("Fast"),
    ;

    companion object {
        val supported: List<MonitorGlesUpscaler> = entries

        fun fromStored(raw: String?): MonitorGlesUpscaler {
            if (raw.isNullOrBlank()) return FAST
            entries.firstOrNull { it.label.equals(raw, ignoreCase = true) }?.let { return it }
            return when (raw) {
                "Lanczos" -> FAST
                "MetalFX", "Quality", "Super Res", "AI" -> FAST
                else -> FAST
            }
        }

        /**
         * Catmull-Rom is for magnification only. A 720p panel (or portrait
         * 1080×608 well) minifies - cubic aliases there and GL_LINEAR is right.
         */
        fun shouldReconstructToDisplay(
            sourceWidth: Float,
            sourceHeight: Float,
            displayWidth: Float,
            displayHeight: Float,
        ): Boolean {
            if (sourceWidth < 1f || sourceHeight < 1f) return false
            val scale =
                maxOf(displayWidth / sourceWidth, displayHeight / sourceHeight)
            return scale > 1.01f
        }
    }
}


data class GlesPresentationOptions(val upscaler: MonitorGlesUpscaler = MonitorGlesUpscaler.FAST)
