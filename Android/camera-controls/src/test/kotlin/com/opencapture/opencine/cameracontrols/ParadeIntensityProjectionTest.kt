package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.ScopeAssistBundle
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.*

/** Fixed deployed opacity vectors; the projection never rewrites the saved operator value. */
class ParadeIntensityProjectionTest {
    @Test fun suppliedProjectionPreservesClampingAndStoredBrightness() {
        val source = MonitorOperatorAssistSource(AssistHost(emptyList(), emptyList(), emptyList()),
            MutableStateFlow(ScopeAssistBundle.EMPTY), {}, null, paradeIntensityScale = .25)
        val vectors = listOf(-20 to 0.0, 0 to 0.0, 25 to .0625, 100 to .25, 200 to .5, 240 to .5)
        for ((brightness, expected) in vectors) {
            assertEquals(expected.toRawBits(), ParadeAssist.intensity(brightness, source.paradeIntensityScale).toRawBits())
        }
        val state = MonitorAssistState()
        state.setParade(brightness = 100)
        assertEquals(.25, ParadeAssist.intensity(state.paradeBrightness, source.paradeIntensityScale))
        assertEquals(100, state.paradeBrightness)
    }

    @Test fun absentProjectionRetainsOriginalPositiveAndClampVectors() {
        val source = MonitorOperatorAssistSource(AssistHost(emptyList(), emptyList(), emptyList()),
            MutableStateFlow(ScopeAssistBundle.EMPTY), {}, null)
        assertEquals(1.0, source.paradeIntensityScale)
        val vectors = listOf(-20 to 0.0, 0 to 0.0, 25 to .25, 100 to 1.0, 200 to 2.0, 240 to 2.0)
        for ((brightness, expected) in vectors) {
            assertEquals(expected.toRawBits(), ParadeAssist.intensity(brightness).toRawBits())
        }
    }

    @Test fun originalOneArgumentFunctionReferenceRemainsAvailable() {
        val project: (Int) -> Double = ParadeAssist::intensity
        assertEquals(.25.toRawBits(), project(25).toRawBits())
        assertEquals(1.0.toRawBits(), project(100).toRawBits())
        assertEquals(2.0.toRawBits(), project(240).toRawBits())
    }
}
