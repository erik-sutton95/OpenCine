package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals

class CameraNetworkPermissionTest {
    @Test fun waitingIsNeitherDenialNorApproval() {
        val observation = CameraNetworkPermissionObservation()
        assertEquals(CameraNetworkPermissionState.UNKNOWN, observation.state)
        val attempt = observation.begin()
        observation.observe(CameraNetworkPermissionEvidence.WAITING, attempt)
        assertEquals(CameraNetworkPermissionState.REQUESTED, observation.state)
    }

    @Test fun onlyExplicitPolicyEvidenceIsDenial() {
        val observation = CameraNetworkPermissionObservation()
        val attempt = observation.begin()
        observation.observe(CameraNetworkPermissionEvidence.POLICY_DENIED, attempt)
        assertEquals(CameraNetworkPermissionState.DENIED, observation.state)
        observation.observe(CameraNetworkPermissionEvidence.WAITING, attempt)
        assertEquals(CameraNetworkPermissionState.DENIED, observation.state)
        observation.observe(CameraNetworkPermissionEvidence.OPERATION_SUCCEEDED, attempt)
        assertEquals(CameraNetworkPermissionState.ALLOWED, observation.state)
    }

    @Test fun retiredEvidenceCannotPoisonOrStopTheSuccessor() {
        val observation = CameraNetworkPermissionObservation()
        val old = observation.begin()
        val current = observation.begin()
        observation.observe(CameraNetworkPermissionEvidence.POLICY_DENIED, old)
        observation.retire(old)
        assertEquals(CameraNetworkPermissionState.REQUESTED, observation.state)
        observation.observe(CameraNetworkPermissionEvidence.OPERATION_SUCCEEDED, current)
        observation.retire(current)
        observation.observe(CameraNetworkPermissionEvidence.POLICY_DENIED, current)
        assertEquals(CameraNetworkPermissionState.ALLOWED, observation.state)
    }
}
