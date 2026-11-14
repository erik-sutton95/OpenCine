package com.opencapture.opencine.core

/**
 * What a commissioner remembers of a camera it may have moved onto a station network: enough to
 * find it again nearby and return it to its own access point after the session closed. The
 * identifiers are the integration's. Swift twin: `StationCameraRecord`, whose `id` is a `UUID` on
 * purpose: Apple names a Bluetooth peripheral by a UUID, Android discovery by text.
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
 * How a camera's return to its own access point ended. The cleanup journal keeps every camera that
 * was not [Restored]. Swift twin: `StationRestoreResult`.
 */
public sealed interface StationRestoreResult {
    public data object Restored : StationRestoreResult

    /**
     * The camera answered but did not return now; [message] tells the operator what to do (for
     * example approve this phone on the camera). Close again to retry.
     */
    public data class Deferred(public val message: String) : StationRestoreResult

    /** The camera did not confirm. */
    public data object Failed : StationRestoreResult
}

/**
 * An integration that moves a nearby camera from its own access point onto a shared station
 * network and back. Optional: an integration whose cameras join a network only from their own
 * menus supplies none. Whether a camera may join a stage and shows a picture is the integration's
 * [MultiviewCameraPolicy], which every integration supplies. Swift twin: `StationCommissioner`.
 */
public interface StationCommissioner<Camera> {
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
     * Returns the camera to its own access point, with the integration's own bounded retry.
     * Cancellation propagates.
     */
    public suspend fun restoreAccessPoint(record: StationCameraRecord): StationRestoreResult

    /** Whether this integration can list the networks a camera sees. Without it [scanNetworks] throws [StationScanUnsupported]. */
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
        throw StationScanUnsupported()
    }
}

/**
 * [StationCommissioner.scanNetworks] of an integration that cannot list networks (its
 * `scansNetworks` is false). A plain exception, never a cancellation, so a caller's job is not
 * silently cancelled. Swift twin: `StationScanUnsupported`.
 */
public class StationScanUnsupported : UnsupportedOperationException("this integration cannot list networks")
