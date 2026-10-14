package com.opencapture.opencine.media

/** Source-calibrated ruler values for the same bands the monitor paints. */
data class MonitorFalseColorReferencePlan(
    val segments: List<Segment>, val markers: List<Marker>, val clipStops: Double,
) {
    data class Segment(val lowerFraction: Double, val upperFraction: Double, val band: LiveFalseColorBand)
    data class Marker(val kind: Kind, val sceneStop: Double, val fraction: Double) {
        enum class Kind { STOP, CLIP }
        val label: String get() = if (kind == Kind.CLIP) "clip" else if (sceneStop == 0.0) "18%"
            else if (sceneStop < 0) "−${(-sceneStop).toInt()}" else "+${sceneStop.toInt()}"
    }
    companion object {
        fun signal(scale: LiveFalseColorScale, transfer: MonitorTransfer, clipByte: Int,
            lookCurve: List<Double>? = null, readThroughLook: Boolean = false): MonitorFalseColorReferencePlan {
            require(clipByte in 1..255)
            val clip = LiveColorScience.falseColorClip(scale, transfer, readThroughLook, lookCurve, clipByte / 255.0)
            val measured = LiveColorScience.stops(LiveColorScience.clipShelf(clip.ceiling), clip.transfer)
            val stops = measured.takeIf { it.isFinite() } ?: LiveColorScience.SCENE_STOP_DEFAULT_CLIP
            val lower = -8.5
            val upper = maxOf(2.5, stops) + 1
            fun fraction(value: Double, fallback: Double): Double {
                if (!value.isFinite()) return fallback
                return (if (scale.usesSceneStops) (value - lower) / (upper - lower) else value / 100.0).coerceIn(0.0, 1.0)
            }
            val segments = LiveColorScience.falseColorBands(scale, clip.transfer, clip.ceiling).map {
                Segment(fraction(it.lowerBound, 0.0), fraction(it.upperBound, 1.0), it)
            }
            val markers = if (scale.usesSceneStops) {
                generateSequence(-6) { it + 2 }.takeWhile { it < stops - 1.5 }.map { stop ->
                    Marker(Marker.Kind.STOP, stop.toDouble(), fraction(stop.toDouble(), 0.0))
                }.toList() + Marker(Marker.Kind.CLIP, stops, fraction(stops, 1.0))
            } else emptyList()
            return MonitorFalseColorReferencePlan(segments, markers, stops)
        }
    }
}
