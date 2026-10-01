package com.opencapture.opencine.core

/**
 * Identity of a picture stream. Frames, decoders and native surfaces live in media runtime
 * products; portable state only names the stream and its generation.
 */
public data class PictureSourceDescriptor(
    public val stream: StreamID = StreamID(),
    public val generation: StreamGeneration = StreamGeneration(),
    /** Display label supplied by the integration or app, for example `HDMI`. */
    public val label: String,
)

/**
 * Picture health, kept apart from control-link health and recording state. A frozen picture
 * does not prove a camera stopped recording; a live picture does not prove control works.
 */
public enum class PictureHealth { STARTING, LIVE, STALLED, FAILED }

public enum class TelemetrySource {
    /** From the entry's own camera session. */
    CAMERA_SESSION,

    /** Forwarded by a relay host while another device holds the camera. */
    RELAY,
}

public enum class MonitorEntryError {
    /** No picture, camera session or telemetry: nothing to monitor. */
    NO_ROLE,

    /** Owner or lease authority without a camera session to submit through. */
    COMMAND_AUTHORITY_WITHOUT_SESSION,
    SESSION_TELEMETRY_WITHOUT_SESSION,
}

/**
 * A monitoring slot composing an optional picture, an optional camera session, telemetry and
 * control authority. Control-only and picture-only entries are both valid. Replacing the picture
 * keeps the camera session and its control epoch.
 *
 * Serializable description only: runtime ownership of the source, session and subscriptions is
 * held elsewhere.
 */
public data class MonitorEntryDescriptor(
    public val id: MonitorEntryID = MonitorEntryID(),
    public val name: String,
    public val device: CameraDeviceID? = null,
    public val picture: PictureSourceDescriptor? = null,
    public val cameraSession: CameraSessionID? = null,
    public val telemetry: TelemetrySource? = null,
    public val controlAuthority: ControlAuthority,
) {
    /** Why this entry is invalid, or `null` when it is valid. */
    public fun validationError(): MonitorEntryError? {
        if (picture == null && cameraSession == null && telemetry == null) return MonitorEntryError.NO_ROLE
        val commands = controlAuthority is ControlAuthority.Owner || controlAuthority is ControlAuthority.Lease
        if (commands && cameraSession == null) return MonitorEntryError.COMMAND_AUTHORITY_WITHOUT_SESSION
        if (telemetry == TelemetrySource.CAMERA_SESSION && cameraSession == null) {
            return MonitorEntryError.SESSION_TELEMETRY_WITHOUT_SESSION
        }
        return null
    }
}
