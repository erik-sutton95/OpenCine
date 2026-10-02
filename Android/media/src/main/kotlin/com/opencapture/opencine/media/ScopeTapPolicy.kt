package com.opencapture.opencine.media

/** Which scopes the GLES present path should tap, and the VECTOR look. */
data class ScopeTapPolicy(
    val inspectorOnly: Boolean = false,
    val previewOwner: Any? = null,
    val playback: Boolean = false,
    val waveform: Boolean = false,
    val parade: Boolean = false,
    val histogram: Boolean = false,
    val vectorscope: Boolean = false,
    val trafficLights: Boolean = false,
    val ndMeter: Boolean = false,
    /** EV meter reading the picture: the scope tap must run. */
    val evMeter: Boolean = false,
    val trafficThreshold: Double = 0.0,
    val transfer: MonitorTransfer = MonitorTransfer.REC709,
    val iso: Int? = null,
    val vectorLut: MonitorLUTCube? = null,
    val allowsTransferInference: Boolean = true,
) {
    val activeScopeCount: Int
        get() = listOf(waveform, parade, histogram, vectorscope, trafficLights, ndMeter, evMeter).count { it }

    val needsTap: Boolean
        get() = activeScopeCount > 0 || previewOwner != null

    val includePoints: Boolean
        get() = waveform || parade

    val includeVectorPoints: Boolean
        get() = vectorscope

    fun minIntervalNs(thermalMultiplier: Double): Long {
        val existing = ScopeSampler.minIntervalNs(activeScopeCount, thermalMultiplier)
        return if (inspectorOnly) maxOf(existing, (200_000_000L * thermalMultiplier.coerceAtLeast(1.0)).toLong()) else existing
    }

    /**
     * Raw tap cadence for both schedulers. An inspector-only scope never drives it past
     * 5 Hz; visible backdrop chrome may still ask for the faster 213×120 tap.
     */
    fun tapIntervalNs(thermalMultiplier: Double, backdropDemand: Boolean): Long =
        ScopeSampler.chromeSampleIntervalNs(
            if (inspectorOnly) 0 else activeScopeCount, thermalMultiplier, backdropDemand)

    /** Scope accumulation admission, independent of a faster backdrop-driven raw tap. */
    fun scopeWorkDue(nowNs: Long, lastScopeWorkNs: Long, thermalMultiplier: Double): Boolean =
        activeScopeCount > 0 &&
            (lastScopeWorkNs == 0L || nowNs - lastScopeWorkNs >= minIntervalNs(thermalMultiplier))

    companion object {
        val IDLE = ScopeTapPolicy()
    }
}
