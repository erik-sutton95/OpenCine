package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Kotlin twin of the Swift `CaptureCodecColorTests`: same cases, same expectations. */
class CaptureCodecColorTest {
    private fun choice(id: String, label: String, editable: Boolean = true) =
        CaptureCodecColorChoice(id = id, label = label, isEditable = editable)

    @Test
    fun bothReadoutsOpenTheOnePopup() {
        assertEquals(CaptureCodecColorReadout.CODEC.popup, CaptureCodecColorReadout.COLOR.popup)
        assertEquals(2, CaptureCodecColorReadout.entries.size)
    }

    @Test
    fun aCameraWithoutCodecChoicesShowsColourOnly() {
        val choices = CaptureCodecColorChoices(
            colors = listOf(choice("normal", "Normal"), choice("dlogm", "D-Log M")),
            selectedColor = "dlogm",
        )
        assertFalse(choices.showsCodec)
        assertTrue(choices.showsColor)
        assertEquals("COLOR", choices.title)
        assertEquals("D-Log M", choices.selectedColorChoice?.label)
    }

    @Test
    fun aCameraWithCodecChoicesShowsBothSectionsInOrder() {
        val choices = CaptureCodecColorChoices(
            codecs = listOf(choice("h265", "H.265 10-bit"), choice("prores", "ProRes 422 HQ")),
            selectedCodec = "h265",
            colors = listOf(choice("sdr", "SDR"), choice("hlg", "HLG"), choice("nlog", "N-Log")),
            selectedColor = "nlog",
        )
        assertTrue(choices.showsCodec && choices.showsColor)
        assertEquals("CODEC · COLOR", choices.title)
        assertEquals(listOf(CaptureCodecColorSection.CODEC, CaptureCodecColorSection.COLOR), choices.sections)
        assertEquals("H.265 10-bit", choices.selectedCodecChoice?.label)
        assertEquals(listOf("SDR", "HLG", "N-Log"), choices.colors.map { it.label })
    }

    @Test
    fun duplicateIdentitiesKeepTheCameraOrderAndTheFirstLabel() {
        val choices = CaptureCodecColorChoices(
            codecs = listOf(choice("a", "A"), choice("b", "B"), choice("a", "A again")),
            colors = emptyList(),
        )
        assertEquals(listOf("A", "B"), choices.codecs.map { it.label })
        assertEquals(listOf(CaptureCodecColorSection.CODEC), choices.sections)
        assertEquals("CODEC", choices.title)
    }

    @Test
    fun anUnlistedSelectionIsUnknownNotTheFirstChoice() {
        val choices = CaptureCodecColorChoices(
            codecs = listOf(choice("h265", "H.265")), selectedCodec = "r3d",
            colors = listOf(choice("sdr", "SDR")), selectedColor = "hlg",
        )
        assertNull(choices.selectedCodec)
        assertNull(choices.selectedColor)
    }

    @Test
    fun aColourFixedByTheCodecIsShownButNotEditable() {
        val choices = CaptureCodecColorChoices(
            codecs = listOf(choice("r3d", "R3D NE")), selectedCodec = "r3d",
            colors = listOf(choice("log3g10", "Log3G10", editable = false)), selectedColor = "log3g10",
        )
        assertTrue(choices.showsColor)
        assertFalse(choices.colorEditable)
        assertTrue(choices.codecEditable)
    }

    @Test
    fun nothingOfferedIsEmpty() {
        assertTrue(CaptureCodecColorChoices.EMPTY.isEmpty)
        assertTrue(CaptureCodecColorChoices.EMPTY.sections.isEmpty())
        assertFalse(CaptureCodecColorChoices(colors = listOf(choice("x", "X"))).isEmpty)
    }
}
