package com.opencapture.opencine.vocabulary

/**
 * Which live header readout carries the app accent: the shooting mode where the body shows one,
 * else the codec. The integration declares it in its static capture profile (`headerAccent`); the
 * shared header never tests a brand. Swift twin: `MonitorHeaderAccent`.
 */
public enum class MonitorHeaderAccent(public val id: String) {
    /** The shooting-mode readout, where the camera reports a mode the header shows. */
    SHOOTING_MODE("shootingMode"),

    /** The codec readout: a body with no shooting-mode readout, as Nikon. */
    CODEC("codec"),
}
