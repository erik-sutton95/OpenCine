package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoice
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoices
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.ControlCapability
import com.opencapture.opencine.vocabulary.ControlStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class ControlDisplaySectionsTest {
    @Test fun displaySectionsFollowTypedSupportWithoutInventingHostServices() {
        val hostSections = MonitorDisplaySection.entries.toSet() - setOf(
            MonitorDisplaySection.ZOOM_CHIP, MonitorDisplaySection.GIMBAL_STICK, MonitorDisplaySection.COLOR)
        val statuses = listOf(ControlStatus(SupportStatus.UNKNOWN), ControlStatus(SupportStatus.UNSUPPORTED),
            ControlStatus(SupportStatus.SUPPORTED), ControlStatus(SupportStatus.SUPPORTED, SettingAccess.READ_ONLY))
        for (status in statuses) {
            val controls = ControlCapabilities().copy(
                zoom = ControlCapability(status.support, status.access),
                gimbal = ControlCapability(status.support, status.access),
                codecColor = ControlCapability(status.support, status.access))
            val sections = controls.displaySections
            assertEquals(status.isOffered, MonitorDisplaySection.ZOOM_CHIP in sections)
            assertEquals(status.isOffered, MonitorDisplaySection.GIMBAL_STICK in sections)
            assertEquals(status.isShown, MonitorDisplaySection.COLOR in sections)
            assertTrue(sections.containsAll(hostSections))
        }
        val codecOnly = ControlCapabilities().copy(codecColor = ControlCapability.supported(
            CaptureCodecColorChoices(codecs = listOf(CaptureCodecColorChoice("codec", "Codec")))))
        assertFalse(MonitorDisplaySection.COLOR in codecOnly.displaySections, "known codec-only values have no color chip")
        val color = codecOnly.copy(codecColor = ControlCapability.supported(
            CaptureCodecColorChoices(colors = listOf(CaptureCodecColorChoice("log", "Log"))), SettingAccess.READ_ONLY))
        assertTrue(MonitorDisplaySection.COLOR in color.displaySections, "a real read-only color remains a readout")
        assertFalse(MonitorDisplaySection.COLOR in color.copy(codecColor = ControlCapability(
            SupportStatus.UNKNOWN, color.codecColor.access, color.codecColor.offer)).displaySections,
            "values do not invent support")
    }
}
