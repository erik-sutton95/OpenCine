package com.opencapture.opencine.media

/**
 * Generated display look with a pure raw decoder and a source-owned Float gamut matrix.
 * Negative decoded channels reach the matrix before output channels clamp.
 */
class MonitorLogDisplayTransform(
    private val decode: (Double) -> Double,
    sourceToRec709: FloatArray,
) {
    private val sourceToRec709 = sourceToRec709.copyOf()

    init { require(sourceToRec709.size == 9) }

    /** Applies the raw decoder, Float matrix and shared scene-anchored display transform. */
    fun map(red: Float, green: Float, blue: Float): Triple<Float, Float, Float> {
        val lr = decode(red.toDouble()).toFloat()
        val lg = decode(green.toDouble()).toFloat()
        val lb = decode(blue.toDouble()).toFloat()
        val m = sourceToRec709
        val outR = maxOf(0f, m[0] * lr + m[1] * lg + m[2] * lb)
        val outG = maxOf(0f, m[3] * lr + m[4] * lg + m[5] * lb)
        val outB = maxOf(0f, m[6] * lr + m[7] * lg + m[8] * lb)
        val tone = MonitorSceneToneMap(decode(1.0).toFloat().toDouble())
        return Triple(tone.displayCode(outR.toDouble()).toFloat(),
            tone.displayCode(outG.toDouble()).toFloat(), tone.displayCode(outB.toDouble()).toFloat())
    }

    /** Red-fastest RGB lattice, retaining the caller's requested dimension. */
    fun rgb(size: Int = 33): FloatArray {
        require(size >= 2)
        val denominator = (size - 1).toFloat()
        val result = FloatArray(size * size * size * 3)
        var index = 0
        for (b in 0 until size) for (g in 0 until size) for (r in 0 until size) {
            val mapped = map(r / denominator, g / denominator, b / denominator)
            result[index++] = mapped.first
            result[index++] = mapped.second
            result[index++] = mapped.third
        }
        return result
    }

    /** Gray-axis reading through Float cube interpolation, before any RGBA8 quantization. */
    fun neutralLumaCurve(cubeSize: Int = 33, sampleCount: Int = 256): List<Double> {
        require(sampleCount >= 2)
        val cube = rgb(cubeSize)
        return List(sampleCount) { index ->
            val code = index.toFloat() / (sampleCount - 1).toFloat()
            val red = sample(cube, cubeSize, code, 0).toDouble()
            val green = sample(cube, cubeSize, code, 1).toDouble()
            val blue = sample(cube, cubeSize, code, 2).toDouble()
            0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
    }

    // Matches CubeLUT.map's Float interpolation order, specialized to the neutral input axis.
    private fun sample(rgb: FloatArray, size: Int, code: Float, channel: Int): Float {
        val position = code.coerceIn(0f, 1f) * (size - 1).toFloat()
        val low = position.toInt()
        val high = minOf(low + 1, size - 1)
        val fraction = position - low.toFloat()
        fun lattice(r: Int, g: Int, b: Int) = rgb[(r + g * size + b * size * size) * 3 + channel]
        val c00 = lattice(low, low, low) * (1 - fraction) + lattice(high, low, low) * fraction
        val c10 = lattice(low, high, low) * (1 - fraction) + lattice(high, high, low) * fraction
        val c01 = lattice(low, low, high) * (1 - fraction) + lattice(high, low, high) * fraction
        val c11 = lattice(low, high, high) * (1 - fraction) + lattice(high, high, high) * fraction
        val c0 = c00 * (1 - fraction) + c10 * fraction
        val c1 = c01 * (1 - fraction) + c11 * fraction
        return c0 * (1 - fraction) + c1 * fraction
    }
}
