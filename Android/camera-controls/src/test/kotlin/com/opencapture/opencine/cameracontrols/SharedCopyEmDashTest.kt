package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.media.MonitorConformPreview
import com.opencapture.opencine.vocabulary.ControlHud
import com.opencapture.opencine.vocabulary.LutCatalog
import kotlin.test.Test
import kotlin.test.assertFalse

/** Owner style rule: operator copy never uses the em dash. Swift twin: `SharedCopyEmDashTests`. */
class SharedCopyEmDashTest {
    @Test fun sharedOperatorCopyHasNoEmDash() {
        val help = OperatorHelpCopy("SIMULATED")
        listOf(
            help.SAVED_CAMERAS, help.JOYSTICK_SENSITIVITY, help.HDR_DISPLAY, help.LINK_HEALTH,
            help.CACHE_FULL_RESOLUTION, NDAssist.HELP, LutCatalog.PHOTO_REC709_CAPTION,
            ControlHud.RECORDING_COLOR_LOCK_NOTE,
            MonitorConformPreview.Availability.VariableRate.unavailableReason.orEmpty(),
        ).forEach { assertFalse(it.contains('—'), it) }
    }
}
