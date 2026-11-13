package com.opencapture.opencine.core

/**
 * What a Multiview member's Auto LUT follows: the camera's reported color mode and the conversion
 * its look profile declares for that mode. The integration or app resolves both; the caption is
 * shared so every app reads the same. Swift twin: `MultiviewAutoLUT`.
 */
public data class MultiviewAutoLUT(
    /** The reported color mode's name; null until the camera reports one. */
    public val colorMode: String?,
    /** The look profile's conversion for that mode (a LUT title); null when none is needed. */
    public val conversion: String?,
) {
    /**
     * The tile's LUT caption. [conversionLoaded] says whether the conversion's cube could be
     * loaded; it matters only while the LUT is enabled.
     */
    public fun caption(enabled: Boolean, conversionLoaded: Boolean): String {
        if (conversion == null) {
            return if (colorMode == null) "Waiting for camera color" else "Auto · no conversion needed"
        }
        if (enabled && !conversionLoaded) return "LUT unavailable"
        return "Auto · $conversion"
    }
}

/** One repair tick's verdict from a member link. Swift twin: `MultiviewRepairStep`. */
public sealed interface MultiviewRepairStep {
    /** Nothing to repair: the coordinator applies its own path-loss rule. */
    public data object Healthy : MultiviewRepairStep

    /** The link repaired in place this tick, or declined to act now. */
    public data object Handled : MultiviewRepairStep

    /**
     * A repair to run as the member's recovery (the coordinator marks the member recovering while
     * it runs). [run] returns true when the link cannot recover in place and the coordinator should
     * rejoin it within its budget.
     */
    public class Repair(public val run: suspend () -> Boolean) : MultiviewRepairStep
}

/** What a member link's repair may read of the coordinator. Swift twin: `MultiviewRepairContext`. */
public class MultiviewRepairContext(
    /** This phone is on the shared network now. */
    public val pathReady: Boolean,
    /** The stage is still running. */
    public val running: () -> Boolean,
    /** The app is in the foreground. */
    public val applicationActive: () -> Boolean,
    /** The app has not left and re-entered the foreground since this tick. */
    public val foregroundUnchanged: () -> Boolean,
    /** This phone is on the shared network at the moment of asking. */
    public val pathAvailable: () -> Boolean,
)

/**
 * One Multiview member's link to its camera on the station network: its common session, its
 * picture, and the steps the coordinator drives (probe, open with an identity check, preview,
 * keepalive, repair, close). An integration or the app supplies it. Swift twin:
 * `MultiviewMemberLink`.
 */
public interface MultiviewMemberLink<Camera> {
    /** The member's camera as a common session, one for the member's lifetime. */
    public val session: CameraSession

    /** The member's picture, apart from its control link. */
    public val pictureHealth: PictureHealth

    /** Whether a camera of this integration may answer at [address] (a port probe). Opens no session. */
    public suspend fun probe(address: String, hotspot: Boolean): Boolean

    /** Opens [camera] at [address] and checks that the camera answering is the one [identity] names. Throws when another camera or nothing answers. */
    public suspend fun open(camera: Camera, address: String, identity: ByteArray, hotspot: Boolean)

    /** Starts the picture on the open link. */
    public suspend fun startPreview(camera: Camera)

    /** Keeps the link alive; the coordinator calls it once a second. */
    public suspend fun keepalive()

    /** Closes the link. Never sends the camera a command. */
    public fun close()

    /** The integration's own repair step, once a second while the member publishes a picture. */
    public fun repair(context: MultiviewRepairContext): MultiviewRepairStep

    /** What the member's Auto LUT follows now. */
    public val autoLUT: MultiviewAutoLUT
}
