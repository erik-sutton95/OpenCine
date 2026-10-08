package com.opencapture.opencine.media

/** The existing Float playback tap projection and ARGB packing; GPU rendering stays native. */
object MonitorPlaybackPixelEffects {
    fun apply(
        px: IntArray,
        width: Int,
        height: Int,
        plan: FeedEffectsRenderPlan,
    ) {
        val lut = plan.lutCube
        val falsePaint = plan.falseColorPaint
        val zebraOn = plan.zebraHighlightOn
        val zebraCode = (plan.zebraHighlightCode * 255f).toInt().coerceIn(0, 255)
        val zr = (plan.zebraHighlightColor.getOrElse(0) { 1f } * 255f).toInt().coerceIn(0, 255)
        val zg = (plan.zebraHighlightColor.getOrElse(1) { 1f } * 255f).toInt().coerceIn(0, 255)
        val zb = (plan.zebraHighlightColor.getOrElse(2) { 1f } * 255f).toInt().coerceIn(0, 255)
        val midOn = plan.zebraMidtoneOn
        val midCode = (plan.zebraMidtoneCode * 255f).toInt().coerceIn(0, 255)
        val midHalf = (plan.zebraMidtoneHalf * 255f).toInt().coerceAtLeast(1)
        val mr = (plan.zebraMidtoneColor.getOrElse(0) { 1f } * 255f).toInt().coerceIn(0, 255)
        val mg = (plan.zebraMidtoneColor.getOrElse(1) { 1f } * 255f).toInt().coerceIn(0, 255)
        val mb = (plan.zebraMidtoneColor.getOrElse(2) { 0f } * 255f).toInt().coerceIn(0, 255)
        val peakOn = plan.peaking
        val pr = (plan.peakingColor.getOrElse(0) { 1f } * 255f).toInt().coerceIn(0, 255)
        val pg = (plan.peakingColor.getOrElse(1) { 0f } * 255f).toInt().coerceIn(0, 255)
        val pb = (plan.peakingColor.getOrElse(2) { 0f } * 255f).toInt().coerceIn(0, 255)
        val src = px.copyOf()
        for (i in px.indices) {
            val p = src[i]
            var r = (p ushr 16) and 0xFF
            var g = (p ushr 8) and 0xFF
            var b = p and 0xFF
            val a = p ushr 24
            if (lut != null) {
                val mapped = lut.map(r / 255f, g / 255f, b / 255f)
                r = (mapped.first * 255f).toInt().coerceIn(0, 255)
                g = (mapped.second * 255f).toInt().coerceIn(0, 255)
                b = (mapped.third * 255f).toInt().coerceIn(0, 255)
            }
            if (falsePaint != null) {
                val mapped = falsePaint.map(r / 255f, g / 255f, b / 255f)
                r = (mapped.first * 255f).toInt().coerceIn(0, 255)
                g = (mapped.second * 255f).toInt().coerceIn(0, 255)
                b = (mapped.third * 255f).toInt().coerceIn(0, 255)
            }
            val luma = (0.2126f * r + 0.7152f * g + 0.0722f * b).toInt()
            if (midOn && kotlin.math.abs(luma - midCode) <= midHalf) {
                r = mr
                g = mg
                b = mb
            }
            // Highlight rides the max channel: same byte WAVE draws at 100 (#136).
            if (zebraOn && maxOf(r, g, b) >= zebraCode) {
                r = zr
                g = zg
                b = zb
            }
            if (peakOn && i >= width && i < px.size - width) {
                val up = src[i - width]
                val ur = (up ushr 16) and 0xFF
                val ug = (up ushr 8) and 0xFF
                val ub = up and 0xFF
                val edge = kotlin.math.abs(r - ur) + kotlin.math.abs(g - ug) + kotlin.math.abs(b - ub)
                if (edge > 80) {
                    r = pr
                    g = pg
                    b = pb
                }
            }
            px[i] = (a shl 24) or (r shl 16) or (g shl 8) or b
        }
    }

    fun argb8888ToRgba(pixels: IntArray): ByteArray {
        val packed = ByteArray(pixels.size * 4)
        var o = 0
        for (p in pixels) {
            packed[o] = (p ushr 16).toByte()
            packed[o + 1] = (p ushr 8).toByte()
            packed[o + 2] = p.toByte()
            packed[o + 3] = (p ushr 24).toByte()
            o += 4
        }
        return packed
    }

}
