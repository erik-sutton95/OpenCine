package com.opencapture.opencine.core

import java.util.UUID
import kotlin.time.Duration
import kotlin.time.Duration.Companion.nanoseconds

/** A saved setup path (USB, a station network, the camera's access point, a relay). One camera can have several routes. */
@JvmInline public value class ConnectionRouteID(public val uuid: UUID = UUID.randomUUID())

/** One attempt to connect or recover. Completions carrying an older attempt are ignored. */
@JvmInline public value class ConnectionAttemptID(public val uuid: UUID = UUID.randomUUID())

/** One owned live camera-control lifetime. Detail views borrow it; they never open a second link. */
@JvmInline public value class CameraSessionID(public val uuid: UUID = UUID.randomUUID())

/** One granted remote control lease. */
@JvmInline public value class ControlLeaseID(public val uuid: UUID = UUID.randomUUID())

/** One picture stream. */
@JvmInline public value class StreamID(public val uuid: UUID = UUID.randomUUID())

/** Stable UI and multicam slot identity. Reordering, staging and rotation keep it. */
@JvmInline public value class MonitorEntryID(public val uuid: UUID = UUID.randomUUID())

/** One command or workflow intent and its results. Unrelated to telemetry revisions. */
@JvmInline public value class OperationID(public val uuid: UUID = UUID.randomUUID())

/**
 * Advances when the control link or control authority of a session is replaced.
 * A picture-format change alone does not advance it.
 */
@JvmInline public value class ControlEpoch(public val value: Long = 0) : Comparable<ControlEpoch> {
    public fun next(): ControlEpoch = ControlEpoch(value + 1)
    override fun compareTo(other: ControlEpoch): Int = value.compareTo(other.value)
}

/** Advances on reconnect or reconfiguration; frames from an older generation are stale. */
@JvmInline public value class StreamGeneration(public val value: Long = 0) : Comparable<StreamGeneration> {
    public fun next(): StreamGeneration = StreamGeneration(value + 1)
    override fun compareTo(other: StreamGeneration): Int = value.compareTo(other.value)
}

/** Advances whenever any setting descriptor (support, domain, access, availability) changes. */
@JvmInline public value class CapabilityRevision(public val value: Long = 0) : Comparable<CapabilityRevision> {
    public fun next(): CapabilityRevision = CapabilityRevision(value + 1)
    override fun compareTo(other: CapabilityRevision): Int = value.compareTo(other.value)
}

/** Advances with every published camera snapshot. */
@JvmInline public value class SnapshotRevision(public val value: Long = 0) : Comparable<SnapshotRevision> {
    public fun next(): SnapshotRevision = SnapshotRevision(value + 1)
    override fun compareTo(other: SnapshotRevision): Int = value.compareTo(other.value)
}

/**
 * Stable namespaced integration identifier, for example `org.example.cameras`.
 * For registration and diagnostics only: shared code never chooses behavior from it.
 */
@JvmInline public value class IntegrationID(public val rawValue: String)

/**
 * Persisted identity of a physical camera.
 *
 * Durable identities come from a serial-like value the integration trusts. When none exists the
 * integration mints a provisional identity, which is a fresh UUID and therefore never derived
 * from a host address, display name or model. Reconciliation rule: a provisional identity equals
 * only itself; common code never merges two devices. When the integration later learns the
 * durable identity it replaces the provisional one explicitly and the app migrates its saved
 * references. Credentials are referenced elsewhere by opaque IDs, never embedded here.
 */
@ConsistentCopyVisibility
public data class CameraDeviceID private constructor(
    public val integration: IntegrationID,
    public val value: String,
    public val isProvisional: Boolean,
) {
    public companion object {
        public fun durable(value: String, integration: IntegrationID): CameraDeviceID =
            CameraDeviceID(integration, value, isProvisional = false)

        public fun provisional(integration: IntegrationID): CameraDeviceID =
            CameraDeviceID(integration, UUID.randomUUID().toString(), isProvisional = true)

        /** An identity read back from storage (Swift: `Codable` decoding). */
        public fun restored(integration: IntegrationID, value: String, isProvisional: Boolean): CameraDeviceID =
            CameraDeviceID(integration, value, isProvisional)
    }
}

/**
 * A point on the host's monotonic clock. Production code takes every instant from [now], the one
 * process-wide reference, so deadlines, lease expiry and observation times from different
 * integrations compare (MULTI-03 F1). Tests inject instants directly, or a `() -> MonotonicInstant`
 * where a session takes one. Instants from different hosts or processes are not comparable.
 */
@JvmInline
public value class MonotonicInstant(public val sinceReference: Duration) : Comparable<MonotonicInstant> {
    public operator fun plus(duration: Duration): MonotonicInstant = MonotonicInstant(sinceReference + duration)
    public operator fun minus(other: MonotonicInstant): Duration = sinceReference - other.sinceReference
    override fun compareTo(other: MonotonicInstant): Int = sinceReference.compareTo(other.sinceReference)

    public companion object {
        public val ZERO: MonotonicInstant = MonotonicInstant(Duration.ZERO)

        /**
         * Now on the shared host reference: `System.nanoTime()` (CLOCK_MONOTONIC on Android), so
         * code that already stamps raw `nanoTime` stays comparable. Every integration and app uses
         * this, never its own origin (`markNow()`, `nanoTime() - start`, `elapsedRealtime`).
         */
        @JvmStatic
        public fun now(): MonotonicInstant = MonotonicInstant(System.nanoTime().nanoseconds)
    }
}
