package com.opencapture.opencine.nikon

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** The colour half of the Z codec and colour popup, listed from the tones Swift decided. */
class NikonCodecColorTest {
    private fun snapshot(tones: List<String>, editable: Boolean, tone: String?) =
        CameraPropertySnapshot(
            codec = "H.265 10-bit MOV",
            movieTone = tone,
            controlCapabilities = CameraControlCapabilities(movieTones = tones, movieToneEditable = editable),
        )

    @Test
    fun theOfferedTonesOfTheActiveCodecAreTheColourSection() {
        val choices = snapshot(listOf("SDR", "HLG", "N-Log"), true, "N-Log").codecColorChoices()
        assertTrue(choices.showsColor)
        assertEquals(listOf("SDR", "HLG", "N-Log"), choices.colors.map { it.label })
        assertEquals("N-Log", choices.selectedColorChoice?.label)
        assertTrue(choices.colorEditable)
    }

    @Test
    fun aFixedToneIsShownAndNotEditable() {
        val choices = snapshot(listOf("Log3G10"), false, "Log3G10").codecColorChoices()
        assertTrue(choices.showsColor)
        assertFalse(choices.colorEditable)
    }

    @Test
    fun aCodecWithoutToneHasNoColour() {
        assertFalse(snapshot(emptyList(), false, null).codecColorChoices().showsColor)
    }
}
