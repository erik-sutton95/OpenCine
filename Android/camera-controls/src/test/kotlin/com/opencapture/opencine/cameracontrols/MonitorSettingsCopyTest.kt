package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Swift twin: `MonitorSettingsCopyParityTests.reliabilityReportsPrivacyIsOneTextOnEveryPlatform`. */
class MonitorSettingsCopyTest {
    @Test fun reliabilityReportsPrivacyStatesTheInstallIdentifierAndTheTogglePlace() {
        val text = MonitorSettingsCopy.reliabilityReportsPrivacy
        listOf(
            "Optional reliability reports\n", "through Sentry",
            "random install identifier that is created when you opt in and deleted when you opt out",
            "Operator Setup > System", "deletes the install identifier", "exclude all images",
        ).forEach { assertTrue(text.contains(it), it) }
        assertFalse(text.contains('—'), "Operator copy never uses the em dash")
    }
}
