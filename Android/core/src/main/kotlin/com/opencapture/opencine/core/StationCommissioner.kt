package com.opencapture.opencine.core

import kotlin.coroutines.cancellation.CancellationException

/**
 * What a commissioner remembers of a camera it may have moved onto a station network: enough to
 * find it again nearby and return it to its own access point after the session closed. The
 * identifiers are the integration's. Swift twin: `StationCameraRecord`.
 */
public data class StationCameraRecord(
    public val id: String,
    public val name: String,
    /** The integration's model code; null when the camera did not report one. */
    public val modelId: Int?,
    /** The camera's Bluetooth address where the platform exposes it. */
    public val deviceAddress: String? = null,
)

/** How a camera's move onto a station network ended. Swift twin: `StationCommissionOutcome`. */
public enum class StationCommissionOutcome {
    /** The camera accepted the network; the caller still finds and identifies it there. */
    JOINED,

    /** The caller's `verifyOnNetwork` already found and identified the camera. */
    VERIFIED,
}

/**
 * One nearby camera's setup link (for example its Bluetooth link) while a commissioner moves it
 * onto a station network. The caller closes it when the move ended either way.
 */
public interface StationCommission {
    /**
     * The integration's proof of this camera: a camera found on the network is this one only when
     * its member link reports the same bytes ([MultiviewMemberLink.open]).
     */
    public suspend fun identity(): ByteArray

    /**
     * Moves the camera onto [network]. [progress] reports operator-facing steps.
     * [verifyOnNetwork] lets the caller find and open the camera on the network while this link is
     * still up; it returns true when it did.
     */
    public suspend fun join(
        network: StationNetwork,
        identity: ByteArray,
        experimental: Boolean,
        progress: (String) -> Unit,
        verifyOnNetwork: suspend () -> Boolean,
    ): StationCommissionOutcome

    public fun close()
}

/**
 * An integration that moves a nearby camera from its own access point onto a shared station
 * network and back. Optional: an integration whose cameras join a network only from their own
 * menus supplies none. Swift twin: `StationCommissioner`.
 */
public interface StationCommissioner<Camera> {
    /** Whether this camera, in this configuration, may join a stage. */
    public fun qualification(camera: Camera, experimental: Boolean): MulticamQualification

    /** Whether a stage shows this camera's picture; without it only the network join is checked. */
    public fun hasPreview(camera: Camera): Boolean

    /** The record kept in the cleanup journal before the camera leaves its access point. */
    public fun record(camera: Camera): StationCameraRecord

    /** Opens the camera's setup link (pairing, waking its Wi-Fi). [progress] reports operator-facing steps. */
    public suspend fun connect(camera: Camera, progress: (String) -> Unit): StationCommission

    /**
     * Closes every commission link still open, connecting or not (the stage stopped). A network
     * scan's link is left to finish returning its camera.
     */
    public fun closeCommissions()

    /**
     * Returns the camera to its own access point, with the integration's own bounded retry. False
     * when the camera did not confirm. Cancellation propagates.
     */
    public suspend fun restoreAccessPoint(record: StationCameraRecord): Boolean

    /** Whether this integration can list the networks a camera sees. */
    public val scansNetworks: Boolean get() = false

    /**
     * Networks [camera] can see, reported as they arrive. [beforeStationChange] runs before the
     * camera leaves its access point (the caller journals the cleanup there and may refuse by
     * throwing); [onRestored] reports whether it returned. The camera is always asked back,
     * cancelled or not.
     */
    public suspend fun scanNetworks(
        camera: Camera,
        beforeStationChange: () -> Unit,
        onRestored: (Boolean) -> Unit,
        onFound: (String) -> Unit,
    ) {
        throw CancellationException("this integration cannot list networks")
    }
}
