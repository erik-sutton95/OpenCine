package com.opencapture.opencine.media

/** Explicit display-only encoded-pixel suppression. Measurement pixels remain pristine. */
data class MonitorBlockSmoothing(val radius: Double = 2.0, val gateLevels: Double = 5.0, val strength: Double = 0.8)
data class MonitorBlockDither(val levels: Double = 3.0)
