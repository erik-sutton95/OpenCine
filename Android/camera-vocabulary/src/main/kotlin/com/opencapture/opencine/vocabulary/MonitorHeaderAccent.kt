package com.opencapture.opencine.vocabulary

/**
 * Which live header readout carries the app accent: the shooting mode, or the codec for a body
 * with no shooting-mode readout. The integration declares it in its static capture profile (`headerAccent`); the
 * shared header never tests a brand. Swift twin: `MonitorHeaderAccent`.
 */
public enum class MonitorHeaderAccent(public val id: String) {
    /** The shooting-mode readout, where the camera reports a mode the header shows. */
    SHOOTING_MODE("shootingMode"),

    /** The codec readout, for a body with no shooting-mode readout. */
    CODEC("codec"),
}
