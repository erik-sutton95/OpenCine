package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.SupportStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ControlCapabilityInputsTest {
    @Test fun dynamicInputsPreserveUnknownReadOnlyAndDeclaredValues() {
        val domain = SettingDomain(choices = listOf(SettingValue.Iso(com.opencapture.opencine.core.ISOValue.Manual(800))))
        val snapshot = CapabilitySnapshot(descriptors = listOf(
            SettingDescriptor(SettingKey.ISO, domain = domain),
            SettingDescriptor(SettingKey.SHUTTER, access = SettingAccess.READ_ONLY)))
        val source = ControlCapabilities.derive(snapshot,
            CameraCaptureProfile(supportsFocusMode = true, supportsZoom = true))
        val controls = source.restricting(mapOf(
            ControlFamily.ISO to ControlStatus(SupportStatus.SUPPORTED, SettingAccess.READ_ONLY),
            ControlFamily.SHUTTER to ControlStatus(SupportStatus.SUPPORTED),
            ControlFamily.FOCUS to ControlStatus(SupportStatus.UNSUPPORTED),
            ControlFamily.ZOOM to ControlStatus(SupportStatus.UNKNOWN),
            ControlFamily.AUDIO to ControlStatus(SupportStatus.SUPPORTED)))
        assertTrue(controls.iso.isShown && !controls.iso.isOffered)
        assertEquals(domain, controls.iso.offer?.setting?.domain)
        assertTrue(controls.shutter.isShown && !controls.shutter.isOffered)
        assertEquals(SupportStatus.UNSUPPORTED, controls.focus.support)
        assertNull(controls.focus.offer)
        assertEquals(SupportStatus.UNKNOWN, controls.zoom.support)
        assertFalse(controls.zoom.isOffered)
        assertEquals(SupportStatus.UNKNOWN, controls.audio.support)
        assertTrue(source.focus.isOffered)
        assertEquals(source, source.restricting(emptyMap()))
    }
}
