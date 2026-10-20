package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.core.CapabilitySnapshot
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingDescriptor
import com.opencapture.opencine.core.SettingDomain
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.motion.MotionAxis
import com.opencapture.opencine.motion.MotionBounds
import com.opencapture.opencine.motion.MotionCapabilities
import com.opencapture.opencine.motion.MotionReferenceFrame
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds

/** The merge rules of the one control model (Swift twin: `ControlCapabilitiesTests`). */
class ControlCapabilitiesTest {
    private val gimbal = MotionCapabilities(
        axes = setOf(MotionAxis.PAN, MotionAxis.TILT), frame = MotionReferenceFrame.HANDLE,
        bounds = MotionBounds(-90.0..90.0, -45.0..45.0), maxRateDegPerSec = null,
        feedbackMaxAge = 300.milliseconds, arrivalToleranceDeg = 0.5, pose = SupportStatus.SUPPORTED,
    )

    @Test
    fun nothingKnownIsUnknownNeverFalse() {
        val controls = ControlCapabilities.derive(CapabilitySnapshot(), null)
        for (family in ControlFamily.entries) assertEquals(SupportStatus.UNKNOWN, controls.status(family).support, family.id)
        assertTrue(controls.offered.isEmpty())
    }

    @Test
    fun aDescriptorDecidesSupportAccessAndValues() {
        val domain = SettingDomain(listOf(SettingValue.Iso(ISOValue.Auto), SettingValue.Iso(ISOValue.Manual(800))))
        val snapshot = CapabilitySnapshot(
            descriptors = listOf(
                SettingDescriptor(SettingKey.ISO, domain = domain),
                SettingDescriptor(SettingKey.FRAME_RATE, SettingAccess.READ_ONLY),
                SettingDescriptor(SettingKey.SHUTTER, SettingAccess.READ_ONLY),
            ),
            unsupported = setOf(SettingKey.WHITE_BALANCE_TINT),
        )
        val controls = ControlCapabilities.derive(snapshot, null)
        assertTrue(controls.iso.isOffered)
        assertEquals(domain, controls.iso.offer?.setting?.domain)
        assertEquals(ControlStatus(SupportStatus.SUPPORTED, SettingAccess.READ_ONLY), controls.shutter.status)
        assertTrue(!controls.shutter.isOffered && controls.shutter.isShown, "read-only is a readout")
        assertEquals(SupportStatus.UNSUPPORTED, controls.tint.support)
        assertEquals(SupportStatus.UNKNOWN, controls.whiteBalance.support)
        assertTrue(controls.recordingFormat.isOffered, "a frame-rate observation means a format to show")
    }

    @Test
    fun profileFlagsAndDeclarationsFillWhatTheSnapshotLacks() {
        val profile = CameraCaptureProfile(
            supportsFocusMode = true, supportsTapFocus = false, supportsAperture = true, hasGimbal = false,
            zoom = CameraZoomProfile(listOf(1.0, 2.0)),
            controls = mapOf(
                ControlFamily.ND_FILTER to SupportStatus.UNSUPPORTED,
                ControlFamily.FACE_METERING to SupportStatus.SUPPORTED,
                ControlFamily.SHUTTER to SupportStatus.SUPPORTED,
            ),
        )
        val snapshot = CapabilitySnapshot(
            descriptors = listOf(SettingDescriptor(SettingKey.APERTURE, SettingAccess.READ_ONLY)),
            unsupported = setOf(SettingKey.ZOOM),
        )
        val controls = ControlCapabilities.derive(snapshot, profile)
        assertTrue(controls.focus.isOffered)
        assertEquals(SupportStatus.UNSUPPORTED, controls.tapFocus.support)
        // A declared iris control over a read-only f-number (a strategy panel) is offered.
        assertTrue(controls.iris.isOffered)
        assertEquals(SupportStatus.UNSUPPORTED, controls.zoom.support, "no flag: the snapshot's unsupported list")
        assertEquals(SupportStatus.UNSUPPORTED, controls.ndFilter.support)
        assertTrue(controls.faceMetering.isOffered)
        assertTrue(controls.shutter.isOffered, "declared where no descriptor exists")
        assertEquals(SupportStatus.UNSUPPORTED, controls.gimbal.support, "a known body without motion has no gimbal")
        assertEquals(SupportStatus.UNSUPPORTED, controls.headTracking.support)
    }

    @Test
    fun aWritableSettingWinsOverAFalseFlag() {
        val profile = CameraCaptureProfile(supportsFocusMode = false, supportsZoom = false)
        val snapshot = CapabilitySnapshot(
            descriptors = listOf(
                SettingDescriptor(SettingKey.FOCUS_POINT),
                SettingDescriptor(SettingKey.ZOOM, domain = SettingDomain(range = 1.0..4.0)),
            ),
        )
        val controls = ControlCapabilities.derive(snapshot, profile)
        assertTrue(controls.focus.isOffered)
        assertTrue(controls.tapFocus.isOffered)
        assertTrue(controls.zoom.isOffered)
    }

    @Test
    fun motionDecidesGimbalAndHeadTracking() {
        val controls = ControlCapabilities.derive(CapabilitySnapshot(), CameraCaptureProfile(hasGimbal = true), gimbal)
        assertTrue(controls.gimbal.isOffered)
        assertEquals(gimbal, controls.gimbal.offer)
        assertTrue(controls.headTracking.isOffered)
        val tilt = ControlCapabilities.derive(CapabilitySnapshot(), null, gimbal.copy(axes = setOf(MotionAxis.TILT)))
        assertEquals(SupportStatus.UNSUPPORTED, tilt.gimbal.support)
        assertEquals(SupportStatus.UNSUPPORTED, tilt.headTracking.support)
        // A body that declares a gimbal but whose motion is not known yet stays unknown.
        val pending = ControlCapabilities.derive(CapabilitySnapshot(), CameraCaptureProfile(hasGimbal = true))
        assertEquals(SupportStatus.UNKNOWN, pending.gimbal.support)
    }

    @Test
    fun observationsAreReadouts() {
        val snapshot = CapabilitySnapshot(
            timecodeCapability = TimecodeCapability.supported(TimecodePrecision.Frames(Rational(25))),
            audioLevels = SupportStatus.SUPPORTED,
        )
        val controls = ControlCapabilities.derive(snapshot, null)
        assertTrue(controls.timecode.isShown && !controls.timecode.isOffered)
        assertEquals(TimecodePrecision.Frames(Rational(25)), controls.timecode.offer)
        assertTrue(controls.liveAudioLevels.isShown && !controls.liveAudioLevels.isOffered)
        assertTrue(controls.audio.isOffered, "a body reporting levels has an input to set")
    }

    @Test
    fun codecColorFollowsTheChoicesTheCameraOffers() {
        val colors = CaptureCodecColorChoices(colors = listOf(CaptureCodecColorChoice("log", "N-Log")))
        assertTrue(ControlCapabilities.derive(CapabilitySnapshot(), null, codecColor = colors).codecColor.isOffered)
        val fixed = CaptureCodecColorChoices(colors = listOf(CaptureCodecColorChoice("l3", "Log3G10", isEditable = false)))
        val readout = ControlCapabilities.derive(CapabilitySnapshot(), null, codecColor = fixed).codecColor
        assertTrue(readout.isShown && !readout.isOffered)
        assertEquals(SupportStatus.UNKNOWN,
            ControlCapabilities.derive(CapabilitySnapshot(), null, codecColor = CaptureCodecColorChoices()).codecColor.support)
    }

    @Test
    fun layoutIsAViewThatKeepsTheBaseWhileUnknown() {
        val base = MonitorLayoutCapabilities(zoom = true, clipStar = true)
        assertEquals(base, MonitorLayoutCapabilities(ControlCapabilities(), base))
        val profile = CameraCaptureProfile(supportsFocusMode = true, hasGimbal = false, supportsZoom = false)
        val known = MonitorLayoutCapabilities(
            ControlCapabilities.derive(CapabilitySnapshot(timecode = SupportStatus.SUPPORTED), profile), base)
        assertTrue(!known.zoom && known.focus && !known.gimbal && known.timecode && known.clipStar)
        assertFalse(known.headTracking)
    }

    @Test
    fun vectorsRenderOneRowPerFamily() {
        val rows = ControlCapabilityVectors.rows("fake", "Body", ControlCapabilities())
        assertEquals(ControlFamily.entries.size, rows.size)
        assertEquals("fake\tBody\tiso\tunknown", rows.first())
        val document = ControlCapabilityVectors.document("fake", listOf("Body" to ControlCapabilities()))
        assertTrue(document.endsWith("multiview\tunknown\n"))
        assertTrue(document.startsWith("# Generated"))
    }

    @Test
    fun familyIdsMatchTheSwiftCaseNames() {
        assertEquals(
            listOf("iso", "shutter", "whiteBalance", "tint", "iris", "ndFilter", "focus", "tapFocus", "faceMetering",
                "exposureCompensation", "codecColor", "recordingFormat", "audio", "liveAudioLevels", "zoom",
                "gimbal", "headTracking", "timecode", "recording", "photo", "media", "mediaDelete", "multiview"),
            ControlFamily.entries.map { it.id },
        )
    }

    @Test
    fun beforeConnectionOnlyTheKnownModelsProfileIsOffered() {
        val none = ControlCapabilities.beforeConnection(null)
        assertTrue(none.offered.isEmpty(), "no model known: no camera-dependent control")
        assertEquals(SupportStatus.UNKNOWN, none.audio.support)
        val profile = CameraCaptureProfile(supportsFocusMode = true, hasGimbal = true, supportsAperture = false)
        val known = ControlCapabilities.beforeConnection(profile, gimbal)
        assertTrue(known.focus.isOffered && known.gimbal.isOffered)
        assertFalse(known.iris.isOffered)
        assertFalse(known.audio.isOffered, "undeclared stays unknown")
        assertEquals(ControlCapabilities.derive(CapabilitySnapshot(), profile, gimbal), known)
    }

    @Test
    fun theStaticProfileDeclaresTheHeaderAccent() {
        assertEquals(MonitorHeaderAccent.SHOOTING_MODE, CameraCaptureProfile().headerAccent,
            "DJI and Insta keep the shooting-mode accent")
        val nikon = CameraCaptureProfile(headerAccent = MonitorHeaderAccent.CODEC)
        assertEquals(MonitorHeaderAccent.CODEC, ControlCapabilities.derive(CapabilitySnapshot(), nikon).headerAccent)
        assertEquals(MonitorHeaderAccent.CODEC, ControlCapabilities.beforeConnection(nikon).headerAccent,
            "the saved body keeps its accent before it reconnects")
        assertEquals(MonitorHeaderAccent.SHOOTING_MODE, ControlCapabilities().headerAccent)
        assertEquals(MonitorHeaderAccent.SHOOTING_MODE, ControlCapabilities.derive(CapabilitySnapshot(), null).headerAccent,
            "no body known never invents a codec accent")
    }
}
