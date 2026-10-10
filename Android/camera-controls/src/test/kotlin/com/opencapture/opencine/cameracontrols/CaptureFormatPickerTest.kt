package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.vocabulary.VideoFormat
import com.opencapture.opencine.vocabulary.VideoFrameRate
import com.opencapture.opencine.vocabulary.VideoResolution
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull

class CaptureFormatPickerTest {
    private val fx = CaptureFormatGroup("FX", "FX")
    private val dx = CaptureFormatGroup("DX", "DX")
    private val four = CaptureFormatGroup("4", "4K")
    private val six = CaptureFormatGroup("6", "6K")
    private val wide = CaptureFormatGroup("wide", "16:9")
    private val tall = CaptureFormatGroup("tall", "9:16")
    private fun choice(token: String, size: CaptureFormatGroup, rate: String,
        area: CaptureFormatGroup? = null, aspect: CaptureFormatGroup? = null, editable: Boolean = true) =
        CaptureFormatChoice(token, token, area, aspect, size, CaptureFormatGroup(rate, rate), editable)

    @Test fun sparseTuplesNeverCreateAnUnsupportedRate() {
        val choices = listOf(choice("4-60", four, "60p"), choice("6-25", six, "25p"), choice("4-25", four, "25p"))
        val state = CaptureFormatPickerState.seat(choices, "4-60")
        val next = state.select(null, null, six, choices, true)
        assertEquals("6-25", next?.value)
        val selected = CaptureFormatPickerState.selected(requireNotNull(next))
        assertEquals(listOf("25p"), selected.visibleChoices(choices).map { it.drumTitle })
        assertNull(selected.selectDrum("60p", choices, true))
        assertEquals(listOf(four, six), state.resolutions(choices))
    }

    @Test fun groupingKeepsTheSelectedRateWhenAdvertisedElseTheFirstTuple() {
        val choices = listOf(choice("4-25", four, "25p"), choice("6-50", six, "50p"), choice("6-25", six, "25p"))
        val state = CaptureFormatPickerState.seat(choices, "4-25")
        assertEquals("6-25", state.select(null, null, six, choices, true)?.value)
        val only50 = choices.take(2)
        assertEquals("6-50", CaptureFormatPickerState.seat(only50, "4-25").select(null, null, six, only50, true)?.value)
    }

    @Test fun identicalVisibleRatesDoNotEraseImageAreaOrExactPayload() {
        val choices = listOf(choice("[FX] 4K · 25p", four, "25p", fx), choice("[DX] 4K · 25p", four, "25p", dx))
        val next = CaptureFormatPickerState.seat(choices, choices[0].value).select(dx, null, four, choices, true)
        assertEquals(choices[1].value, next?.value)
        assertEquals(listOf(choices[1]), CaptureFormatPickerState.selected(requireNotNull(next)).visibleChoices(choices))
    }

    @Test fun imageAreaAndAspectStayIndependent() {
        val choices = listOf(choice("FX-wide", four, "25p", fx, wide), choice("FX-tall", four, "25p", fx, tall), choice("DX-wide", four, "25p", dx, wide))
        val next = CaptureFormatPickerState.seat(choices, "FX-wide").select(fx, tall, four, choices, true)
        val state = CaptureFormatPickerState.selected(requireNotNull(next))
        assertEquals("FX-tall", next?.value)
        assertEquals(fx, state.imageArea)
        val dxChoice = state.select(dx, tall, four, choices, true)
        assertEquals("DX-wide", dxChoice?.value)
        assertEquals(wide, dxChoice?.aspect)
    }

    @Test fun unclassifiedTokensAreRetainedWithoutInventedFacts() {
        val choices = listOf(choice("4-25", four, "25p"), CaptureFormatChoice("future exact token", "future exact token"))
        val next = CaptureFormatPickerState.seat(choices, "4-25").select(null, null, null, choices, true)
        assertEquals("future exact token", next?.value)
        assertNull(next?.imageArea); assertNull(next?.frameRate); assertNull(next?.resolution)
        assertEquals(listOf("future exact token"), CaptureFormatPickerState.selected(requireNotNull(next)).visibleChoices(choices).map { it.drumTitle })
    }

    @Test fun emptyReadOnlyAndRemovedChoicesNeverSubmit() {
        val empty = CaptureFormatPickerState.seat<String>(emptyList(), null)
        assertNull(empty.selectDrum("25p", emptyList(), true))
        val choices = listOf(choice("4-25", four, "25p"), choice("6-50", six, "50p"))
        val state = CaptureFormatPickerState.seat(choices, "4-25")
        assertNull(state.select(null, null, six, choices, false))
        assertEquals("4-25", state.value)
        assertNull(state.select(null, null, six, choices.take(1), true))
        assertNull(state.selectDrum("60p", choices, true))
    }

    @Test fun currentOnlyVocabularyPairStaysVisibleAndInert() {
        val current = VideoFormat(VideoResolution.P1080, VideoFrameRate.FPS240)
        val choices = CaptureVideoFormatChoices.make(emptyList(), current)
        assertEquals(listOf(current), choices.map { it.value })
        assertFalse(choices.single().isEditable)
        val state = CaptureFormatPickerState.seat(choices, current)
        assertNull(state.selectDrum("240p", choices, true))
        assertEquals(listOf("240p"), state.visibleChoices(choices).map { it.drumTitle })
    }

    @Test fun ambiguousVisibleRatesRefuseEveryPayloadOrderAndCurrentIdentity() {
        val known = VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS25)
        val unknown = VideoFormat(VideoResolution.P4K, VideoFrameRate(0x25))
        val unique = VideoFormat(VideoResolution.P4K, VideoFrameRate.FPS60)
        assertEquals(false, known == unknown)
        assertEquals("25p", known.frameRate.drumLabel)
        assertEquals("25p", unknown.frameRate.drumLabel)
        for (advertised in listOf(listOf(known, unknown, unique), listOf(unknown, known, unique))) {
            val choices = CaptureVideoFormatChoices.make(advertised, null)
            for (current in listOf(known, unknown, unique)) {
                val state = CaptureFormatPickerState.seat(choices, current)
                val before = state
                assertNull(state.selectDrum("25p", choices, true))
                assertEquals(before, state)
                if (current == unique) {
                    assertNull(state.selectDrum("60p", choices, true))
                    assertEquals(before, state)
                } else {
                    val picked = state.selectDrum("60p", choices, true)
                    assertEquals(choices.first { it.value == unique }, picked)
                    assertEquals(unique, CaptureFormatPickerState.selected(requireNotNull(picked)).value)
                }
            }
        }
        val choices = CaptureVideoFormatChoices.make(listOf(known, unique), unknown)
        val state = CaptureFormatPickerState.seat(choices, unknown)
        val before = state
        assertNull(state.selectDrum("25p", choices, true))
        assertEquals(before, state)
        val picked = state.selectDrum("60p", choices, true)
        assertEquals(choices.first { it.value == unique }, picked)
        assertEquals(unique, CaptureFormatPickerState.selected(requireNotNull(picked)).value)
    }
}
