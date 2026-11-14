package com.opencapture.opencine.core

import kotlin.time.Duration

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

/**
 * How a member link is doing, reported as it changes ([MultiviewMemberLink.onStatus]). The
 * coordinator owns the tile: it maps each status to the tile's copy and owns the member's control
 * host. Swift twin: `MultiviewLinkStatus`.
 */
public enum class MultiviewLinkStatus {
    /** `open` is reaching the camera at its address and checking who it is. */
    OPENING,

    /**
     * `startPreview` brought the control link up at the address `open` reached: the coordinator
     * may record that host as the member's and control the camera through it.
     */
    CONTROLLING,

    /** The picture was asked for and none has arrived yet. */
    AWAITING_PICTURE,

    /** The picture is arriving. */
    LIVE,

    /** The link is repairing its picture in place. */
    RECONNECTING,
}

/** How a repair the coordinator ran ended. Swift twin: `MultiviewRepairResult`. */
public sealed interface MultiviewRepairResult {
    /** The repair ended; the link's next repair tick judges the picture again. */
    public data object Done : MultiviewRepairResult

    /** The link cannot recover in place: the coordinator rejoins the member within its budget. */
    public data object Rejoin : MultiviewRepairResult

    /**
     * No automatic step remains: the coordinator fails the member with [message] and waits for the
     * operator's Reconnect.
     */
    public data class WaitForOperator(public val message: String) : MultiviewRepairResult

    /** The coordinator's race against a link's deadline lives in `:appkit` (`race`). */
    public companion object
}

/** One repair tick's verdict from a member link. Swift twin: `MultiviewRepairStep`. */
public sealed interface MultiviewRepairStep {
    /** Nothing to repair: the coordinator applies its own path-loss rule. */
    public data object Healthy : MultiviewRepairStep

    /** The link repaired in place this tick, or declined to act now. */
    public data object Handled : MultiviewRepairStep

    /**
     * A repair to run as the member's recovery. The coordinator marks the member recovering while
     * it runs, races it against the link's `repairDeadline` (`:appkit` `MultiviewRepairResult.race`)
     * and acts on its result.
     */
    public class Repair(public val run: suspend () -> MultiviewRepairResult) : MultiviewRepairStep

    /**
     * No automatic step remains (the link's own ladder or the budget it asked is spent, or another
     * device took the camera): the coordinator fails the member with [message] and waits for the
     * operator's Reconnect.
     */
    public data class WaitForOperator(public val message: String) : MultiviewRepairStep
}

/**
 * What a member link's repair may read and ask of the coordinator while it decides and while its
 * repair runs. Swift twin: `MultiviewRepairContext`.
 */
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
    /**
     * Spends one automatic attempt from the coordinator's recovery budget for this member; false
     * when the budget is spent (the link then ends with `WaitForOperator`). A link whose ladder pays
     * per attempt asks before each one; the coordinator also spends one per `Rejoin`.
     */
    public val beginAttempt: () -> Boolean,
    /**
     * Waits for this member's turn on the coordinator's Bluetooth queue (adds and other members'
     * Bluetooth repairs take turns). Returns the release to call when the link no longer needs
     * Bluetooth, or null when the stage stopped first. A repair that uses Bluetooth asks inside its
     * `Repair` block; LAN-only repairs never ask.
     */
    public val bluetoothTurn: suspend () -> (() -> Unit)?,
)

/**
 * One Multiview member's link to its camera on the station network: its common session, its
 * picture, and the steps the coordinator drives (probe, open with an identity check, preview,
 * keepalive, repair, close). An integration or the app supplies it. The coordinator owns the tile
 * (its copy, control host, failure and budget); the link reports through [onStatus] and
 * [isPublishing]. Swift twin: `MultiviewMemberLink`.
 */
public interface MultiviewMemberLink<Camera> {
    /** The member's camera as a common session, one for the member's lifetime. */
    public val session: CameraSession

    /** The member's picture, apart from its control link. */
    public val pictureHealth: PictureHealth

    /** Where the link reports its status, on the main thread; the coordinator sets it once per member. */
    public var onStatus: ((MultiviewLinkStatus) -> Unit)?

    /** The link asked for the picture and keeps it flowing (from `startPreview` until the next `open`). */
    public val isPublishing: Boolean

    /**
     * The longest one of this link's `repair` blocks may run before the coordinator gives up on it
     * (`:appkit` `MultiviewRepairResult.race`). The link bounds its own steps within it.
     */
    public val repairDeadline: Duration

    /**
     * Whether a camera of this integration may answer at [address] on [network] (a port probe).
     * Opens no session and never disturbs a camera another member holds. Asked only when the policy
     * `discoversByProbe`.
     */
    public suspend fun probe(address: String, network: StationNetwork): Boolean

    /**
     * Opens [camera] at [address] on [network] and returns the identity the camera answering proved
     * (the same bytes its [StationCommission.identity] reports). With [expecting], throws when
     * another camera answers; without it (a camera picked from sightings), the caller keeps what it
     * returns. Throws when nothing answers. The link remembers the address for [startPreview]; the
     * coordinator refuses a camera already in the group.
     */
    public suspend fun open(camera: Camera, address: String, expecting: ByteArray?, network: StationNetwork): ByteArray

    /** Starts the picture on the link [open] left open, at the address it reached. */
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
