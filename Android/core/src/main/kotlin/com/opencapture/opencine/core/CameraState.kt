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
 * `Observation.value == null`.
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
    public val media: Observation<MediaState> = Observation.unknown,
    public val freeBytes: Observation<Long> = Observation.unknown,
    /** Reported or estimated; the observation origin says which. */
    public val remainingRecordingTime: Observation<Duration> = Observation.unknown,
)

/** Unknown storage is `value == null`; a camera reporting no volumes is an empty list. */
public typealias StorageStatus = Observation<List<StorageVolume>>

public data class PowerStatus(
    /** Fraction 0..1, with the camera's reporting precision. */
    public val battery: Observation<Double> = Observation.unknown,
    public val charging: Observation<Boolean> = Observation.unknown,
    public val externalPower: Observation<Boolean> = Observation.unknown,
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

/** The latest state of one camera session. Missing data stays unknown. */
public data class CameraSnapshot(
    public val session: CameraSessionID,
    public val epoch: ControlEpoch = ControlEpoch(),
    public val revision: SnapshotRevision = SnapshotRevision(),
    public val device: CameraDeviceID? = null,
    public val connection: ConnectionState = ConnectionState.Discovered,
    public val authority: ControlAuthority = ControlAuthority.Unavailable(UnavailableReason.Link),
    public val capabilities: CapabilitySnapshot = CapabilitySnapshot(),
    public val mode: Observation<CaptureMode> = Observation.unknown,
    /** Keyed by [SettingValue.key]. A missing key is an unknown value. */
    public val settings: Map<SettingKey, Observation<SettingValue>> = emptyMap(),
    public val recording: Observation<RecordingState> = Observation.unknown,
    public val power: PowerStatus = PowerStatus.unknown,
    public val storage: StorageStatus = Observation.unknown,
) {
    public fun value(key: SettingKey): Observation<SettingValue> = settings[key] ?: Observation.unknown
}
