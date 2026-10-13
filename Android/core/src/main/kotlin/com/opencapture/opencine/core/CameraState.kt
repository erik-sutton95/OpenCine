package com.opencapture.opencine.core

import kotlin.time.Duration

/**
 * A common operating role plus an integration-owned mode identity. The integration keeps the
 * wire mapping; Core never enumerates manufacturers' raw capture modes.
 */
public data class CaptureMode(
    public val role: Role,
    /** Namespaced and stable, for example `org.example.cameras.slow-motion`. */
    public val id: String,
    public val title: String,
) {
    public enum class Role { VIDEO, PHOTO, OTHER }
}

/**
 * Camera-reported recording state only. Requested start/stop and pending confirmation are
 * operation progress ([CommandReceipt]), never a fabricated reported state. Unknown is
 * `ObservedValue.value == null`.
 */
public enum class RecordingState {
    IDLE,
    RECORDING,

    /** The camera itself reports that it is starting or stopping. */
    TRANSITIONING,

    /** The camera itself reports a recording error. */
    ERROR,
}

public enum class SessionCloseReason {
    REQUESTED,

    /** A replacement session took over this camera. */
    REPLACED,
    LINK_LOST,
    FAILED,
}

public enum class ConnectionPhase {
    LINK,

    /** The operator must approve on the camera. */
    AWAITING_APPROVAL,
    JOINING_NETWORK,
    NEGOTIATING,
}

/** Control-link state. Picture health is separate ([PictureHealth]). */
public sealed interface ConnectionState {
    public data object Discovered : ConnectionState

    public data class Connecting(
        public val attempt: ConnectionAttemptID,
        public val phase: ConnectionPhase,
    ) : ConnectionState

    public data object Ready : ConnectionState

    public data class Recovering(public val attempt: ConnectionAttemptID) : ConnectionState

    public data class Disconnected(public val reason: SessionCloseReason) : ConnectionState
}

public enum class MediaState { READY, ABSENT, FULL, ERROR }

public data class StorageVolume(
    /** Integration-owned volume identity, stable while the session lives. */
    public val id: String,
    public val media: ObservedValue<MediaState> = ObservedValue.unknown,
    public val freeBytes: ObservedValue<Long> = ObservedValue.unknown,
    /** Reported or estimated; the observation origin says which. */
    public val remainingRecordingTime: ObservedValue<Duration> = ObservedValue.unknown,
    public val totalBytes: ObservedValue<Long> = ObservedValue.unknown,
)

/** Unknown storage is `value == null`; a camera reporting no volumes is an empty list. */
public typealias StorageStatus = ObservedValue<List<StorageVolume>>

public data class PowerStatus(
    /** Fraction 0..1, with the camera's reporting precision. */
    public val battery: ObservedValue<Double> = ObservedValue.unknown,
    public val charging: ObservedValue<Boolean> = ObservedValue.unknown,
    public val externalPower: ObservedValue<Boolean> = ObservedValue.unknown,
) {
    public companion object {
        public val unknown: PowerStatus = PowerStatus()
    }
}

public data class ControlLease(
    public val id: ControlLeaseID = ControlLeaseID(),
    /** `null` when the lease lasts until revoked. */
    public val expiresAt: MonotonicInstant? = null,
)

public sealed interface ControlAuthority {
    /** This device owns the control link. */
    public data object Owner : ControlAuthority

    /** Commands are allowed while this remote lease is valid. */
    public data class Lease(public val lease: ControlLease) : ControlAuthority

    /** Picture and telemetry only. */
    public data object ReadOnly : ControlAuthority

    public data class Unavailable(public val reason: UnavailableReason) : ControlAuthority

    public val leaseID: ControlLeaseID? get() = (this as? Lease)?.lease?.id
}

/**
 * SMPTE-style timecode: the camera's own counter, or time of day an integration derives from a
 * clock (origin `CLOCK_DERIVED`, which never claims that cameras are synchronized). How precisely
 * the source counts is [CapabilitySnapshot.timecode]'s precision.
 */
public data class CameraTimecode(
    public val hours: Int,
    public val minutes: Int,
    public val seconds: Int,
    /**
     * The frame count the source reported; `null` when it knows whole seconds only. Never derived
     * from a clock or a frame rate.
     */
    public val frames: Int? = null,
    /** `null` when the camera does not say whether it counts drop-frame. */
    public val dropFrame: Boolean? = null,
)

/**
 * Live audio level telemetry in dBFS (0 is full scale). Live levels only: live audio samples,
 * camera audio settings and recorded clip audio metadata are separate, and none of them implies
 * that a camera reports levels (plan 6.5).
 */
public data class AudioLevels(public val left: Channel, public val right: Channel) {
    public data class Channel(
        public val level: Double,
        /** The camera's held peak; `null` when it reports none. */
        public val peak: Double? = null,
    )
}

/** The latest state of one camera session. Missing data stays unknown. */
public data class CameraSnapshot(
    public val session: CameraSessionID,
    public val epoch: ControlEpoch = ControlEpoch(),
    public val revision: SnapshotRevision = SnapshotRevision(),
    public val device: CameraDeviceID? = null,
    public val connection: ConnectionState = ConnectionState.Discovered,
    public val authority: ControlAuthority = ControlAuthority.Unavailable(UnavailableReason.Link),
    public val capabilities: CapabilitySnapshot = CapabilitySnapshot(),
    public val mode: ObservedValue<CaptureMode> = ObservedValue.unknown,
    /** Keyed by [SettingValue.key]. A missing key is an unknown value. */
    public val settings: Map<SettingKey, ObservedValue<SettingValue>> = emptyMap(),
    public val recording: ObservedValue<RecordingState> = ObservedValue.unknown,
    public val power: PowerStatus = PowerStatus.unknown,
    public val storage: StorageStatus = ObservedValue.unknown,
    /** Support is [CapabilitySnapshot.timecode]. */
    public val timecode: ObservedValue<CameraTimecode> = ObservedValue.unknown,
    /** Support is [CapabilitySnapshot.audioLevels]. */
    public val audioLevels: ObservedValue<AudioLevels> = ObservedValue.unknown,
) {
    public fun value(key: SettingKey): ObservedValue<SettingValue> = settings[key] ?: ObservedValue.unknown
}
