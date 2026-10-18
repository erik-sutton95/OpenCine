package com.opencapture.opencine.nikon

import com.opencapture.opencine.vocabulary.CaptureCodecColorChoice
import com.opencapture.opencine.vocabulary.CaptureCodecColorChoices

/**
 * The colour half of a Z body's codec and colour popup, from the Swift-decided snapshot: the tones
 * offered for the active codec (R3D NE: Log3G10, shown and fixed) and the one it records. Codec
 * rows stay on the CODEC ladder. Kotlin face of Swift `NikonMovieToneCapability.codecColorChoices`,
 * whose tone decisions the snapshot already carries.
 */
fun CameraPropertySnapshot.codecColorChoices(): CaptureCodecColorChoices {
    val capabilities = controlCapabilities
    return CaptureCodecColorChoices(
        colors = capabilities.movieTones.map { CaptureCodecColorChoice(it, it, capabilities.movieToneEditable) },
        selectedColor = movieTone,
    )
}
