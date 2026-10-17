package com.opencapture.opencine.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorConnectionPolicyTest {
    @Test fun connectionOwnershipKeepsCommandsSeparateFromReadings() {
        for (owns in listOf(false, true)) {
            for (metadata in listOf(false, true)) {
                for (token in listOf(false, true)) {
                    val policy = MonitorConnectionPolicy(owns, metadata, token)
                    assertEquals(owns || token, policy.canDriveCamera)
                    assertEquals(owns || token, policy.cameraControls)
                    assertEquals(owns || token, policy.recordControl)
                    assertEquals(owns, policy.mediaBrowser)
                    assertEquals(owns, policy.offersSourceSwitch)
                    assertEquals(metadata, policy.focusBoxes)
                    assertEquals(metadata, policy.focusConfirmation)
                    assertEquals(metadata, policy.subjectDetectionBoxes)
                    assertEquals(metadata, policy.audioMeters)
                    assertEquals(metadata, policy.cameraTimecode)
                    assertEquals(metadata, policy.cameraLevel)
                }
            }
        }
        assertTrue(MonitorConnectionPolicy.OWNING.cameraControls)
        assertFalse(MonitorConnectionPolicy.watcher(false).cameraControls)
        assertTrue(MonitorConnectionPolicy.watcher(true).cameraControls)
        assertFalse(MonitorConnectionPolicy.watcher(true).mediaBrowser)
    }
}
