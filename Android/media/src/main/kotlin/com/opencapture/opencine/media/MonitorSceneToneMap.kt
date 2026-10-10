package com.opencapture.opencine.media

import kotlin.math.pow

/** Generic scene-linear display transform; source decoding and scene white are adapter inputs. */
class MonitorSceneToneMap(sceneWhite: Double, val contrast: Double = DEFAULT_CONTRAST) {
    val whitePoint = maxOf(sceneWhite / 0.18, 0.000_001)
    private val contrastedWhite = whitePoint.pow(contrast)
    private val whiteContribution = 1 / (contrastedWhite * contrastedWhite)
    private val gain = maxOf(0.000_001,
        (MIDDLE_GRAY_DISPLAY_LINEAR - whiteContribution) / (1 - MIDDLE_GRAY_DISPLAY_LINEAR))
    private val whiteReinhard = gain * contrastedWhite

    fun displayLinear(sceneLinear: Double): Double {
        val x = maxOf(0.0, sceneLinear) / 0.18
        val contrasted = gain * x.pow(contrast)
        val white = whiteReinhard
        val mapped = contrasted * (1 + contrasted / (white * white)) / (1 + contrasted)
        return minOf(1.0, maxOf(0.0, mapped))
    }

    fun displayCode(sceneLinear: Double): Double = displayLinear(sceneLinear).pow(1 / 2.4)
    fun ire(sceneLinear: Double): Double = displayCode(sceneLinear) * 100

    override fun equals(other: Any?): Boolean = other is MonitorSceneToneMap &&
        contrast == other.contrast && whitePoint == other.whitePoint
    override fun hashCode(): Int = 31 * contrast.hashCode() + whitePoint.hashCode()

    companion object {
        val MIDDLE_GRAY_DISPLAY_LINEAR = 0.42.pow(2.4)
        const val DEFAULT_CONTRAST = 1.1
    }
}
