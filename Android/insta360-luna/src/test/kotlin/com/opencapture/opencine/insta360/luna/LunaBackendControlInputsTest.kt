package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.insta360.shell.CameraCapability
import com.opencapture.opencine.insta360.shell.ConnectionPhase
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.ControlCapabilityVectors
import com.opencapture.opencine.vocabulary.ControlFamily
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest

class LunaBackendControlInputsTest {
    @Test fun backendInputsRestrictConnectedControlsWithoutChangingPreConnectionProfile() = runTest {
        val camera = FakeLuna(backgroundScope)
        var backend: Set<CameraCapability>? = null
        val session = camera.connectedSession(backendCapabilities = { backend })
        val original = session.controlCapabilities()
        backend = emptySet()
        val unavailable = session.controlCapabilities()
        for (family in listOf(ControlFamily.ISO, ControlFamily.SHUTTER, ControlFamily.WHITE_BALANCE, ControlFamily.TINT,
            ControlFamily.FOCUS, ControlFamily.TAP_FOCUS, ControlFamily.ZOOM, ControlFamily.GIMBAL,
            ControlFamily.HEAD_TRACKING, ControlFamily.FACE_METERING, ControlFamily.EXPOSURE_COMPENSATION,
            ControlFamily.CODEC_COLOR, ControlFamily.RECORDING_FORMAT, ControlFamily.RECORDING,
            ControlFamily.MEDIA, ControlFamily.MEDIA_DELETE)) {
            assertEquals(SupportStatus.UNSUPPORTED, unavailable.status(family).support, family.id)
        }
        backend = setOf(CameraCapability.CAMERA_SETTINGS, CameraCapability.FOCUS)
        val focus = session.controlCapabilities()
        assertTrue(focus.focus.isOffered && focus.tapFocus.isOffered)
        assertEquals(SupportStatus.UNSUPPORTED, focus.zoom.support)
        assertEquals(SupportStatus.UNKNOWN, unavailable.multiview.support)
        assertEquals(original.timecode, unavailable.timecode)
        assertEquals(com.opencapture.opencine.core.ConnectionState.Ready, session.snapshots.value.connection)
        session.linkChanged(ConnectionPhase.IDLE)
        assertTrue(session.snapshots.value.connection != com.opencapture.opencine.core.ConnectionState.Ready)
        backend = emptySet()
        assertEquals(SupportStatus.UNSUPPORTED, session.controlCapabilities().focus.support)
        val before = ControlCapabilities.beforeConnection(LunaCameraSession.CAPTURE_PROFILE, LunaCameraSession.MOTION)
        assertTrue(before.focus.isOffered && before.zoom.isOffered && before.gimbal.isOffered)
        backend = null
        assertEquals(original.focus, session.controlCapabilities().focus)
    }

    @Test fun fullBackendInputKeepsTheFrozenLunaFixture() = runTest {
        val camera = FakeLuna(backgroundScope)
        val session = camera.connectedSession(backendCapabilities = {
            setOf(CameraCapability.LIVE_VIDEO, CameraCapability.GIMBAL, CameraCapability.ZOOM,
                CameraCapability.FOCUS, CameraCapability.TRACKING, CameraCapability.CAMERA_SETTINGS,
                CameraCapability.RECORD, CameraCapability.CAMERA_MEDIA)
        })
        val document = ControlCapabilityVectors.document("luna", listOf("Luna Ultra" to session.controlCapabilities()))
        assertEquals(File(System.getProperty("opencine.fixtures"), "control-capabilities-luna.tsv").readText(), document)
    }

    @Test fun nativeIsoHopInputKeepsItsExistingBackendMeaning() = runTest {
        var backend = setOf(CameraCapability.CAMERA_SETTINGS, CameraCapability.NATIVE_ISO_HOP)
        val camera = FakeLuna(backgroundScope)
        val session = camera.connectedSession(backendCapabilities = { backend })
        assertEquals(true, session.controlCapabilities().nativeISO.hop)
        backend = setOf(CameraCapability.CAMERA_SETTINGS)
        assertEquals(false, session.controlCapabilities().nativeISO.hop)
    }
}
