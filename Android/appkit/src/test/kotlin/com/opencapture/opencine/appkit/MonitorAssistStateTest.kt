package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import org.json.JSONObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorAssistStateTest {
    @Test fun legacySelectionsKeepTheirActualStoredMeaning() {
        val state = MonitorAssistState(encoded = """{"tools":["WAVE","FALSE","ZEBRA"],"falseColorScale":"CineStop","zebraUnit":"Native","waveCenter":{"xFraction":0.25,"yFraction":0.75},"crushClipCompensation":2,"audioCenter":{"xFraction":0.1,"yFraction":0.2}}""")
        assertEquals(MonitorFalseColorSelection.STOPS, state.falseColorScale)
        assertEquals(MonitorZebraUnit.NATIVE, state.zebraUnit)
        assertEquals(MonitorScopeStoredCenter(0.25, 0.75), state.waveCenter)
        assertEquals(MonitorCrushClipCompensation.QUARTER, state.crushClipCompensation)
        assertEquals(state.audioCenter, state.audioCenterFor(false))
        assertEquals(state.audioCenter, state.audioCenterFor(true))
        val encoded = JSONObject(state.encoded())
        assertEquals("CineStop", encoded.getString("falseColorScale"))
        assertEquals("Native", encoded.getString("zebraUnit"))
        assertEquals(2, encoded.getInt("crushClipCompensation"))
        assertEquals(0.25, encoded.getJSONObject("waveCenter").getDouble("xFraction"))
        assertFalse(encoded.has("configureTool") || encoded.has("longPressAnchor") || encoded.has("scopeBundle"))
    }

    @Test fun rotatedPlacementsReloadWithoutChangingAnotherNamespace() {
        val saved = mutableMapOf<String, String>()
        val first = MonitorAssistState(onPersist = { saved["first"] = it })
        val other = MonitorAssistState(onPersist = { saved["other"] = it })
        assertTrue(saved.isEmpty())
        first.storeCenter(MonitorAssistTool.WAVE, MonitorScopeStoredCenter(0.75, 0.5))
        first.storeCenter(MonitorAssistTool.WAVE, MonitorScopeStoredCenter(0.5, 0.5), portrait = true)
        first.setScale(MonitorAssistTool.WAVE, 5.0)
        first.storeAudioCenter(MonitorScopeStoredCenter(0.2, 0.3), portrait = false)
        first.storeAudioCenter(MonitorScopeStoredCenter(0.4, 0.5), portrait = true)
        val restored = MonitorAssistState(encoded = saved["first"])
        assertEquals(MonitorScopeStoredCenter(0.75, 0.5), restored.centerFor(MonitorAssistTool.WAVE, false))
        assertEquals(MonitorScopeStoredCenter(0.5, 0.5), restored.centerFor(MonitorAssistTool.WAVE, true))
        assertEquals(1.6, restored.waveScale)
        assertEquals(MonitorScopeStoredCenter(0.2, 0.3), restored.audioCenterFor(false))
        assertEquals(MonitorScopeStoredCenter(0.4, 0.5), restored.audioCenterFor(true))
        assertEquals(null, other.waveCenter)
        assertFalse(saved.containsKey("other"))
    }

    @Test fun liveVisibilityPinsAndPlaybackHaveIndependentPersistenceSinks() {
        var blob: String? = null
        var pins: Set<String>? = null
        var playback: Set<String>? = null
        val state = MonitorAssistState(onPersist = { blob = it },
            onPersistPins = { pins = it }, onPersistPlayback = { playback = it })
        state.toggle(MonitorAssistTool.WAVE)
        state.clean = true
        assertTrue(state.isOn(MonitorAssistTool.WAVE))
        assertFalse(state.isVisible(MonitorAssistTool.WAVE))
        state.togglePin(MonitorAssistTool.WAVE)
        assertTrue(state.isVisible(MonitorAssistTool.WAVE))
        state.togglePlayback(MonitorAssistTool.FALSE)
        assertFalse(state.isOn(MonitorAssistTool.FALSE))
        assertTrue(state.isPlaybackVisible(MonitorAssistTool.FALSE))
        assertTrue(pins.orEmpty().contains("WAVE"))
        assertEquals(setOf("FALSE"), playback)
        val restored = MonitorAssistState(encoded = blob, pinnedNames = pins.orEmpty(), playbackNames = playback.orEmpty())
        assertTrue(restored.isOn(MonitorAssistTool.WAVE))
        assertTrue(restored.pinned.contains(MonitorAssistTool.WAVE))
        assertFalse(restored.isOn(MonitorAssistTool.FALSE))
        assertTrue(restored.isPlaybackVisible(MonitorAssistTool.FALSE))
    }

    @Test fun explicitToggleSideEffectPreservesLiveAndPlaybackPersistenceOrder() {
        val events = mutableListOf<String>()
        var persistedLive = false
        var persistedPlayback = false
        lateinit var state: MonitorAssistState
        state = MonitorAssistState(
            onPersist = { persistedLive = JSONObject(it).getJSONArray("tools").toString().contains("FALSE") },
            onPersistPlayback = { persistedPlayback = "FALSE" in it },
            onToggle = { tool, enabled ->
                if (events.size < 2) {
                    assertEquals(enabled, state.isOn(tool))
                    assertEquals(!enabled, persistedLive)
                } else {
                    assertEquals(enabled, state.isPlaybackVisible(tool))
                    assertEquals(enabled, persistedPlayback)
                }
                events += "${tool.name}:$enabled"
            },
        )
        state.toggle(MonitorAssistTool.FALSE)
        state.toggle(MonitorAssistTool.FALSE)
        state.togglePlayback(MonitorAssistTool.FALSE)
        state.togglePlayback(MonitorAssistTool.FALSE)
        assertEquals(listOf("FALSE:true", "FALSE:false", "FALSE:true", "FALSE:false"), events)
        state.clean = true
        state.togglePin(MonitorAssistTool.FALSE)
        state.togglePlayback(MonitorAssistTool.EV)
        assertEquals(4, events.size)
    }

    @Test fun nilToggleSideEffectRetainsOriginalStorageAndScopeOrdering() {
        val plainWrites = mutableListOf<String>()
        val observedWrites = mutableListOf<String>()
        val plainPlayback = mutableListOf<Set<String>>()
        val observedPlayback = mutableListOf<Set<String>>()
        var calls = 0
        val plain = MonitorAssistState(onPersist = { plainWrites += it }, onPersistPlayback = { plainPlayback += it })
        val observed = MonitorAssistState(onPersist = { observedWrites += it },
            onPersistPlayback = { observedPlayback += it }, onToggle = { _, _ -> calls++ })
        for (state in listOf(plain, observed)) {
            state.toggle(MonitorAssistTool.FALSE)
            state.toggle(MonitorAssistTool.WAVE)
            state.togglePlayback(MonitorAssistTool.ZEBRA)
            state.togglePlayback(MonitorAssistTool.ZEBRA)
        }
        assertEquals(plainWrites, observedWrites)
        assertEquals(plainPlayback, observedPlayback)
        assertEquals(plain.scopeStack, observed.scopeStack)
        assertEquals(4, calls)
        assertFalse(JSONObject(plain.encoded()).has("onToggle"))
        plain.toggle(MonitorAssistTool.FALSE)
        assertEquals(4, calls)
        assertTrue(observed.falseColor)
    }
}
