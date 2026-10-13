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
)

/** Unknown storage is `value == null`; a camera reporting no volumes is an empty list. */
public typealias StorageStatus = ObservedValue<List<StorageVolume>>

public data class PowerStatus(
    /** Fraction 0..1, with the camera's reporting precision. */
    public val battery: ObservedValue<Double> = ObservedValue.unknown,
    public val charging: ObservedValue<Boolean> = ObservedValue.unknown,
    public val externalPower: ObservedValue<Boolean> = ObservedValue.unknown,
    /** Whether the source reports battery exhaustion; independent of the charge level. */
    public val exhausted: ObservedValue<Boolean> = ObservedValue.unknown,
) {
    /**
     * The battery as its source declared it; `null` when unknown, which shared chrome shows as
     * absent rather than an empty gauge (D11).
     */
    public val batteryReading: BatteryReading?
        get() {
            val value = battery.value?.takeIf { it.isFinite() } ?: return null
            val fraction = value.coerceIn(0.0, 1.0)
            val steps = BatteryReading.gaugeSteps(battery.precision) ?: return BatteryReading.Fraction(fraction)
            return BatteryReading.Steps(Math.round(fraction * steps).toInt().coerceIn(0, steps), steps)
        }

    public companion object {
        public val unknown: PowerStatus = PowerStatus()
    }
}

/**
 * What a battery observation says, at the precision its source declared. Shared chrome renders
 * this value; it never guesses a gauge from a brand or a percent from a gauge.
 */
public sealed interface BatteryReading {
    /** A charge fraction, 0..1 (a percentage report or a phone). */
    public data class Fraction(public val value: Double) : BatteryReading

    /** [filled] of [of] gauge steps (a five-bar gauge); never a percentage. */
    public data class Steps(public val filled: Int, public val of: Int) : BatteryReading

    /** Portable fields used by the relay codecs; no platform JSON dependency in Core. */
    public val wireFields: BatteryReadingFields
        get() = when (this) {
            is Fraction -> {
                require(value.isFinite() && value in 0.0..1.0) { "Battery fraction must be finite and within 0..1" }
                BatteryReadingFields(kind = "fraction", value = value)
            }
            is Steps -> {
                require(of > 0 && filled in 0..of) { "Battery steps must lie within the declared gauge" }
                BatteryReadingFields(kind = "steps", filled = filled, of = of)
            }
        }

    public companion object {
        /** Mirrors Swift BatteryReading's Codable fields and validation. */
        public fun fromWireFields(fields: BatteryReadingFields): BatteryReading = when (fields.kind) {
            "fraction" -> {
                val value = fields.value
                require(value != null && value.isFinite() && value in 0.0..1.0) {
                    "Battery fraction must be finite and within 0..1"
                }
                Fraction(value)
            }
            "steps" -> {
                val filled = fields.filled
                val count = fields.of
                require(filled != null && count != null && count > 0 && filled in 0..count) {
                    "Battery steps must lie within the declared gauge"
                }
                Steps(filled, count)
            }
            else -> throw IllegalArgumentException("Unknown battery reading kind")
        }

        /**
         * The step count a declared precision implies: a source reporting in steps of 1/2 to 1/10
         * has a gauge, a finer one (percent) reports a fraction.
         */
        internal fun gaugeSteps(precision: ObservationPrecision?): Int? {
            val step = (precision as? ObservationPrecision.Quantized)?.step ?: return null
            if (!step.isFinite() || step <= 0.0) return null
            val count = Math.round(1 / step).toDouble()
            return if (count in 2.0..10.0 && kotlin.math.abs(1 / step - count) < 0.000001) count.toInt() else null
        }
    }
}

/** Stable field names shared by the portable Swift and Kotlin relay payloads. */
public data class BatteryReadingFields(
    public val kind: String,
    public val value: Double? = null,
    public val filled: Int? = null,
    public val of: Int? = null,
)

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
