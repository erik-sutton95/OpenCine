package com.opencapture.opencine.core

import java.util.UUID

/**
 * Current evidence, distinct from a remembered permission acknowledgement. Twin of the Swift
 * values; the Apple Local Network denial rule has no Android counterpart and stays in Swift.
 */
public enum class CameraNetworkPermissionState { UNKNOWN, REQUESTED, ALLOWED, DENIED }

/** Only completed local operations and explicit policy signals determine permission. */
public enum class CameraNetworkPermissionEvidence { WAITING, OPERATION_SUCCEEDED, POLICY_DENIED }

/** Attempt-scoped evidence. Retired callbacks cannot change a replacement's permission state. */
public class CameraNetworkPermissionObservation {
    public var state: CameraNetworkPermissionState = CameraNetworkPermissionState.UNKNOWN
        private set
    private var current: UUID? = null

    public fun begin(): UUID = UUID.randomUUID().also {
        current = it
        state = CameraNetworkPermissionState.REQUESTED
    }

    public fun observe(evidence: CameraNetworkPermissionEvidence, attempt: UUID) {
        if (current != attempt) return
        when (evidence) {
            CameraNetworkPermissionEvidence.WAITING -> Unit
            CameraNetworkPermissionEvidence.OPERATION_SUCCEEDED -> state = CameraNetworkPermissionState.ALLOWED
            CameraNetworkPermissionEvidence.POLICY_DENIED -> state = CameraNetworkPermissionState.DENIED
        }
    }

    public fun retire(attempt: UUID) {
        if (current == attempt) current = null
    }
}
