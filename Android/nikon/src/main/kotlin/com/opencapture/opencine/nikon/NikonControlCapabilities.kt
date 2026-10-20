package com.opencapture.opencine.nikon

import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.vocabulary.CameraCaptureProfile
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoices
import com.opencapture.opencine.vocabulary.ControlCapabilities
import com.opencapture.opencine.vocabulary.ControlFamily
import com.opencapture.opencine.vocabulary.MonitorHeaderAccent

/**
 * Nikon Z static control facts (Swift `NikonCameraSession.captureProfile`): focus modes and tap
 * focus on every body, no motion service (no gimbal, so no head tracking), no built-in ND, movie
 * audio input settings, the codec and colour (movie tone) and recording format lists the body
 * reports, photo, the card served and deleted over PTP, and a multi-camera stage. Zoom stays
 * unknown (power-zoom lenses exist); the setting descriptors come live from the body. The header
 * carries the accent on the codec: a Z body has no shooting-mode readout.
 */
val NIKON_CAPTURE_PROFILE: CameraCaptureProfile = CameraCaptureProfile(
    supportsFocusMode = true, supportsTapFocus = true, hasGimbal = false,
    headerAccent = MonitorHeaderAccent.CODEC,
    controls = mapOf(
        ControlFamily.ND_FILTER to SupportStatus.UNSUPPORTED,
        ControlFamily.AUDIO to SupportStatus.SUPPORTED,
        ControlFamily.RECORDING_FORMAT to SupportStatus.SUPPORTED,
        ControlFamily.CODEC_COLOR to SupportStatus.SUPPORTED,
        ControlFamily.PHOTO to SupportStatus.SUPPORTED,
        ControlFamily.MEDIA to SupportStatus.SUPPORTED,
        ControlFamily.MEDIA_DELETE to SupportStatus.SUPPORTED,
        ControlFamily.MULTIVIEW to SupportStatus.SUPPORTED,
    ),
)

/**
 * The one control model for the connected body (Swift `controlCapabilities(codecColor:)`):
 * [NIKON_CAPTURE_PROFILE] merged with the live capabilities. [codecColor] is what the codec and
 * colour popup lists now, when the host has it.
 */
fun NikonOpenCineSession.controlCapabilities(codecColor: CaptureCodecColorChoices? = null): ControlCapabilities =
    ControlCapabilities.derive(snapshots.value.capabilities, NIKON_CAPTURE_PROFILE, null, codecColor)
