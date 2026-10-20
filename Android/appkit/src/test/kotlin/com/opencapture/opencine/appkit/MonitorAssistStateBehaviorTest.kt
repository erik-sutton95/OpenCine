package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.monitorui.MonitorGuideAspect
import com.opencapture.monitorui.MonitorParadeMode
import com.opencapture.monitorui.MonitorScopeGuides
import com.opencapture.monitorui.MonitorScopeStoredCenter
import com.opencapture.monitorui.MonitorVectorscopeZoom
import com.opencapture.monitorui.MonitorWaveformMode
import com.opencapture.monitorui.MonitorZebraUnit
import com.opencapture.opencine.media.MonitorCrushClipCompensation
import com.opencapture.opencine.media.MonitorPeakingColor
import com.opencapture.opencine.media.MonitorPeakingSense
import com.opencapture.opencine.media.MonitorZebraPaint
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MonitorAssistStateBehaviorTest {
    @Test
    fun lutExposureSliderUsesAbsoluteSnappedValuesWithoutAccumulating() {
        val state = MonitorAssistState()
        state.updateLutExposure(1.1)
        state.updateLutExposure(1.2)
        assertEquals(1.0, state.lutExposureStops)
        state.updateLutExposure(9.0)
        assertEquals(3.0, state.lutExposureStops)
        state.updateLutExposure(-9.0)
        assertEquals(-3.0, state.lutExposureStops)
    }

    @Test
    fun toolbarOrderMatchesPocketCinemaSet() {
        assertEquals(
            listOf(
                MonitorAssistTool.LUT,
                MonitorAssistTool.PEAK,
                MonitorAssistTool.FALSE,
                MonitorAssistTool.ZEBRA,
                MonitorAssistTool.WAVE,
                MonitorAssistTool.PARADE,
                MonitorAssistTool.HISTO,
                MonitorAssistTool.VECTOR,
                MonitorAssistTool.LIGHTS,
                MonitorAssistTool.ND,
                MonitorAssistTool.EV,
                MonitorAssistTool.GUIDES,
                MonitorAssistTool.GRID,
                MonitorAssistTool.CROSS,
                MonitorAssistTool.LEVEL,
                MonitorAssistTool.DESQ,
                MonitorAssistTool.MIRROR,
            ),
            MonitorAssistTool.toolbarCases,
        )
        assertEquals(MonitorAssistTool.AUDIO, MonitorAssistTool.settingsCases.last())
        assertFalse(MonitorAssistTool.toolbarCases.contains(MonitorAssistTool.AUDIO))
    }

    @Test
    fun audioAndMirrorHaveOptionsWhileEvAndLevelStayTapOnly() {
        assertTrue(MonitorAssistTool.AUDIO.hasConfiguration)
        assertFalse(MonitorAssistTool.EV.hasConfiguration)
        assertFalse(MonitorAssistTool.LEVEL.hasConfiguration)
        assertTrue(MonitorAssistTool.MIRROR.hasConfiguration)
        for (tool in MonitorAssistTool.settingsCases) {
            if (tool == MonitorAssistTool.AUDIO || tool == MonitorAssistTool.EV || tool == MonitorAssistTool.LEVEL) continue
            assertTrue(tool.hasConfiguration, "${tool.name} should open options")
        }
    }

    @Test
    fun lutDefaultsOnLikeIos() {
        val state = MonitorAssistState()
        assertTrue(state.lutOn)
        assertTrue(state.isOn(MonitorAssistTool.LUT))
        assertFalse(state.isOn(MonitorAssistTool.PEAK))
        assertFalse(state.mirror)
        assertFalse(state.clean)
        assertEquals(MonitorAssistState.defaultPinned, state.pinned)
    }

    @Test
    fun toggleAndCleanPinsFilterVisibility() {
        val state = MonitorAssistState()
        state.toggle(MonitorAssistTool.WAVE)
        assertTrue(state.isOn(MonitorAssistTool.WAVE))
        assertTrue(state.isVisible(MonitorAssistTool.WAVE))
        state.clean = true
        assertTrue(state.isOn(MonitorAssistTool.WAVE))
        assertFalse(state.isVisible(MonitorAssistTool.WAVE))
        assertTrue(state.isVisible(MonitorAssistTool.LUT))
        state.togglePin(MonitorAssistTool.WAVE)
        assertTrue(state.isVisible(MonitorAssistTool.WAVE))
    }

    @Test
    fun bringToFrontPutsTheScopeLastAndRoundTrips() {
        var saved: String? = null
        val state = MonitorAssistState(onPersist = { saved = it })
        assertEquals(MonitorAssistState.defaultScopeStack, state.scopeStack)
        state.toggle(MonitorAssistTool.WAVE)
        state.toggle(MonitorAssistTool.PARADE)
        assertEquals(MonitorAssistTool.PARADE, state.scopeStack.last())
        state.bringToFront(MonitorAssistTool.WAVE)
        assertEquals(MonitorAssistTool.WAVE, state.scopeStack.last())
        assertTrue(state.scopeStack.toSet() == MonitorAssistState.stackableScopeTools.toSet())
        val restored = MonitorAssistState(encoded = saved)
        assertEquals(MonitorAssistTool.WAVE, restored.scopeStack.last())
        assertEquals(state.scopeStack, restored.scopeStack)
    }

    @Test
    fun encodedRoundTripsOnToolsAndLut() {
        var saved: String? = null
        val state = MonitorAssistState(onPersist = { saved = it })
        state.toggle(MonitorAssistTool.GRID)
        state.toggle(MonitorAssistTool.MIRROR)
        state.updateLutExposure(-1.5)
        assertTrue(saved!!.contains("GRID"))
        val restored = MonitorAssistState(encoded = saved)
        assertTrue(restored.isOn(MonitorAssistTool.LUT))
        assertTrue(restored.isOn(MonitorAssistTool.GRID))
        assertTrue(restored.isOn(MonitorAssistTool.MIRROR))
        assertTrue(restored.lutOn)
        assertEquals(-1.5, restored.lutExposureStops)
    }

    @Test
    fun mirrorAxesPersistAndOnlyApplyWhileToolIsOn() {
        var saved: String? = null
        val state = MonitorAssistState(onPersist = { saved = it })
        assertTrue(state.mirrorHorizontal)
        assertFalse(state.mirrorVertical)
        state.setMirrorAxes(horizontal = false, vertical = true)
        assertFalse(state.flipsVertically)
        state.toggle(MonitorAssistTool.MIRROR)
        assertFalse(state.mirrorsHorizontally)
        assertTrue(state.flipsVertically)
        val restored = MonitorAssistState(encoded = saved)
        assertTrue(restored.isOn(MonitorAssistTool.MIRROR))
        assertFalse(restored.mirrorHorizontal)
        assertTrue(restored.mirrorVertical)
        // Pre-axis saves keep the old horizontal-only behavior.
        val legacy = MonitorAssistState(encoded = """{"tools":["MIRROR"]}""")
        assertTrue(legacy.mirrorsHorizontally)
        assertFalse(legacy.flipsVertically)
    }

    @Test
    fun lutArmedSurvivesEvenIfToolsOmitLut() {
        val json = """{"tools":["GRID"],"lutArmed":true}"""
        val state = MonitorAssistState(encoded = json)
        assertTrue(state.lutOn)
        assertTrue(state.isOn(MonitorAssistTool.GRID))
        val off = MonitorAssistState(encoded = """{"tools":["GRID"],"lutArmed":false}""")
        assertFalse(off.lutOn)
        assertTrue(off.isOn(MonitorAssistTool.GRID))
    }

    @Test
    fun guidesToggleKeepsCinemaDefault() {
        val state = MonitorAssistState()
        state.toggle(MonitorAssistTool.GUIDES)
        assertEquals(setOf(MonitorGuideAspect.CINEMA), state.selectedGuides)
        state.toggleGuide(MonitorGuideAspect.WIDE)
        assertEquals(setOf(MonitorGuideAspect.CINEMA, MonitorGuideAspect.WIDE), state.selectedGuides)
        state.toggleGuide(MonitorGuideAspect.CINEMA)
        assertEquals(setOf(MonitorGuideAspect.WIDE), state.selectedGuides)
        assertTrue(state.guides)
        state.toggleGuide(MonitorGuideAspect.WIDE)
        assertTrue(state.selectedGuides.isEmpty())
        assertFalse(state.guides)
    }

    @Test
    fun syncVisibleAppliesToolSetWithoutClearingPins() {
        val state = MonitorAssistState()
        state.syncVisible(setOf(MonitorAssistTool.GRID, MonitorAssistTool.WAVE), guideRatio = 1.85f)
        assertTrue(state.isOn(MonitorAssistTool.GRID))
        assertTrue(state.isOn(MonitorAssistTool.WAVE))
        assertFalse(state.lutOn)
        assertEquals(MonitorGuideAspect.WIDE, state.guideAspect)
        assertEquals(MonitorAssistState.defaultPinned, state.pinned)
        assertEquals("GRID", MonitorAssistTool.GRID.label)
    }

    @Test
    fun playbackToolbarIncludesAudioAndCinemaSet() {
        assertTrue(MonitorAssistTool.playbackToolbarCases.contains(MonitorAssistTool.AUDIO))
        assertTrue(MonitorAssistTool.playbackToolbarCases.contains(MonitorAssistTool.FALSE))
        assertTrue(MonitorAssistTool.playbackToolbarCases.contains(MonitorAssistTool.ZEBRA))
        assertEquals(MonitorAssistTool.AUDIO, MonitorAssistTool.playbackToolbarCases.last())
        assertFalse(MonitorAssistTool.playbackToolbarCases.contains(MonitorAssistTool.EV))
        assertFalse(MonitorAssistTool.playbackToolbarCases.contains(MonitorAssistTool.LEVEL))
        assertEquals(MonitorAssistTool.toolbarCases.filter { it != MonitorAssistTool.EV && it != MonitorAssistTool.LEVEL },
            MonitorAssistTool.playbackToolbarCases.dropLast(1))
    }

    @Test
    fun playbackToolsAreIndependentOfLiveAndPersistSeparately() {
        var liveSaved = 0
        var playbackSaved: Set<String>? = null
        val state =
            MonitorAssistState(
                onPersist = { liveSaved += 1 },
                onPersistPlayback = { playbackSaved = it },
                playbackNames = setOf("FALSE"),
            )
        assertTrue(state.isPlaybackVisible(MonitorAssistTool.FALSE))
        assertFalse(state.isOn(MonitorAssistTool.FALSE))
        assertTrue(state.playbackVisibleTools.isNotEmpty())
        val afterLive = liveSaved
        state.togglePlayback(MonitorAssistTool.ZEBRA)
        assertTrue(state.isPlaybackVisible(MonitorAssistTool.ZEBRA))
        assertFalse(state.isOn(MonitorAssistTool.ZEBRA))
        assertEquals(afterLive, liveSaved)
        assertEquals(setOf("FALSE", "ZEBRA"), playbackSaved)
        state.togglePlayback(MonitorAssistTool.FALSE)
        assertFalse(state.isPlaybackVisible(MonitorAssistTool.FALSE))
        assertEquals(setOf("ZEBRA"), playbackSaved)
    }
    @Test
    fun newWindowPreferencesRoundTripWithoutSeedingExistingCenters() {
        val fresh = MonitorAssistState()
        assertEquals(null, fresh.waveCenter)
        assertEquals(null, fresh.audioCenter)
        assertEquals(com.opencapture.monitorui.MonitorAudioOrientation.VERTICAL, fresh.audioOrientation)
        assertFalse(fresh.audioShowDB)
        val wave = MonitorScopeStoredCenter(.72, .36)
        val audio = MonitorScopeStoredCenter(.14, .5)
        val reference = MonitorScopeStoredCenter(.4, .6)
        fresh.storeCenter(MonitorAssistTool.WAVE, wave)
        fresh.storeAudioCenter(audio, portrait = true)
        fresh.storeCenter(MonitorAssistTool.FALSE, reference)
        fresh.updateAudioOrientation(com.opencapture.monitorui.MonitorAudioOrientation.HORIZONTAL)
        fresh.updateAudioShowDB(true)
        fresh.toggle(MonitorAssistTool.WAVE)
        fresh.toggle(MonitorAssistTool.WAVE)
        val restored = MonitorAssistState(fresh.encoded())
        assertEquals(wave, restored.waveCenter)
        assertEquals(audio, restored.audioCenter)
        assertEquals(reference, restored.falseColorReferenceCenter)
        assertEquals(com.opencapture.monitorui.MonitorAudioOrientation.HORIZONTAL, restored.audioOrientation)
        assertTrue(restored.audioShowDB)
        assertEquals(null, restored.paradeCenter)
        assertEquals(null, restored.waveCenterPortrait)
    }

    @Test
    fun scopeCentersPersistIndependentlyByOrientationAndLegacyStaysLandscape() {
        val landscape = MonitorScopeStoredCenter(.72, .36)
        val portrait = MonitorScopeStoredCenter(.2, .8)
        val state = MonitorAssistState()
        state.storeCenter(MonitorAssistTool.HISTO, landscape, portrait = false)
        assertEquals(landscape, state.centerFor(MonitorAssistTool.HISTO, false))
        assertEquals(null, state.centerFor(MonitorAssistTool.HISTO, true))
        state.storeCenter(MonitorAssistTool.HISTO, portrait, portrait = true)
        assertEquals(landscape, state.centerFor(MonitorAssistTool.HISTO, false))
        assertEquals(portrait, state.centerFor(MonitorAssistTool.HISTO, true))
        val restored = MonitorAssistState(state.encoded())
        assertEquals(landscape, restored.histoCenter)
        assertEquals(portrait, restored.histoCenterPortrait)
        assertEquals(landscape, restored.centerFor(MonitorAssistTool.HISTO, false))
        assertEquals(portrait, restored.centerFor(MonitorAssistTool.HISTO, true))

        val legacy = org.json.JSONObject()
            .put("histoCenter", org.json.JSONObject().put("xFraction", 0.25).put("yFraction", 0.4))
            .toString()
        val migrated = MonitorAssistState(legacy)
        assertEquals(MonitorScopeStoredCenter(0.25, 0.4), migrated.histoCenter)
        assertEquals(null, migrated.histoCenterPortrait)
        assertEquals(MonitorScopeStoredCenter(0.25, 0.4), migrated.centerFor(MonitorAssistTool.HISTO, false))
        assertEquals(null, migrated.centerFor(MonitorAssistTool.HISTO, true))
    }

    @Test
    fun audioCentersPersistIndependentlyAndKeepALegacyPlacement() {
        val portrait = MonitorScopeStoredCenter(.14, .5)
        val landscape = MonitorScopeStoredCenter(.82, .28)
        val state = MonitorAssistState()
        state.storeAudioCenter(landscape, portrait = false)
        assertEquals(null, state.audioCenterFor(true))
        assertEquals(landscape, state.audioCenterFor(false))
        val restored = MonitorAssistState(state.encoded())
        assertEquals(null, restored.audioCenterFor(true))
        assertEquals(landscape, restored.audioCenterFor(false))
        restored.storeAudioCenter(portrait, portrait = true)
        assertEquals(portrait, restored.audioCenterFor(true))
        assertEquals(landscape, restored.audioCenterFor(false))
        val both = MonitorAssistState(restored.encoded())
        assertEquals(portrait, both.audioCenterFor(true))
        assertEquals(landscape, both.audioCenterFor(false))

        val legacy = MonitorScopeStoredCenter(.2, .4)
        val legacyJson = org.json.JSONObject()
            .put("audioCenter", org.json.JSONObject().put("xFraction", legacy.xFraction).put("yFraction", legacy.yFraction))
            .toString()
        val migrated = MonitorAssistState(legacyJson)
        assertEquals(legacy, migrated.audioCenter)
        assertEquals(legacy, migrated.audioCenterFor(true))
        assertEquals(legacy, migrated.audioCenterFor(false))
        val moved = MonitorScopeStoredCenter(.31, .62)
        migrated.storeAudioCenter(moved, portrait = true)
        assertEquals(moved, migrated.audioCenterFor(true))
        assertEquals(legacy, migrated.audioCenterFor(false))
        val again = MonitorAssistState(migrated.encoded())
        assertEquals(moved, again.audioCenterFor(true))
        assertEquals(legacy, again.audioCenterFor(false))
        assertEquals(null, MonitorAssistState().audioCenterFor(true))
        assertEquals(null, MonitorAssistState().audioCenterFor(false))
    }


    @Test
    fun levelTogglesPersistsAndStaysLiveOnly() {
        var saved: String? = null
        val state = MonitorAssistState(onPersist = { saved = it })
        assertEquals("Level", MonitorAssistTool.LEVEL.title)
        assertFalse(state.isVisible(MonitorAssistTool.LEVEL))
        state.toggle(MonitorAssistTool.LEVEL)
        assertTrue(state.level)
        assertTrue(state.isVisible(MonitorAssistTool.LEVEL))
        val restored = MonitorAssistState(encoded = saved)
        assertTrue(restored.level)
        restored.togglePlayback(MonitorAssistTool.LEVEL)
        assertFalse(restored.isPlaybackVisible(MonitorAssistTool.LEVEL))
    }

    @Test
    fun cardResetsRestoreTheDefaultsAndKeepPanelSizes() {
        val state = MonitorAssistState()
        state.setFalseColor(MonitorFalseColorSelection.LIMITS, reference = false)
        state.setPeaking(MonitorPeakingColor.BLUE, MonitorPeakingSense.HIGH)
        state.updateZebraUnit(MonitorZebraUnit.NATIVE)
        state.setZebraHighlight(false, 42.0, MonitorZebraPaint.CYAN)
        state.setZebraMidtone(false, 12.0, MonitorZebraPaint.GREEN)
        state.setWaveform(MonitorWaveformMode.LUMA, 180, MonitorScopeGuides(false, false, false), 1.4)
        state.setParade(MonitorParadeMode.YRGB, 170, MonitorScopeGuides(false, false, false), 1.3)
        state.setVectorscope(MonitorVectorscopeZoom.X4, 160, 1.2)
        state.setHistogram(false, MonitorCrushClipCompensation.ONE, 0.8)

        MonitorAssistTool.entries.forEach(state::resetSettings)

        // Resetting False Color's reference key also turns the tool on, as each card's Reset always has.
        val expected = MonitorAssistState().apply {
            setWaveform(scale = 1.4)
            setParade(scale = 1.3)
            setVectorscope(scale = 1.2)
            setHistogram(scale = 0.8)
            setFalseColor(reference = true)
        }
        assertEquals(expected.encoded(), state.encoded())
    }

    @Test
    fun standardDefaultsKeepTheSharedZebraAndCompensation() {
        val state = MonitorAssistState()
        assertEquals(MonitorAssistDefaults.STANDARD, state.defaults)
        assertEquals(99.0, state.zebraHighlightIRE)
        assertEquals(MonitorCrushClipCompensation.ZERO, state.crushClipCompensation)
    }

    /** An app's declared defaults seed a fresh state and are where each Reset lands (ZAA-227, ZAA-228). */
    @Test
    fun declaredDefaultsSeedAFreshStateAndEachReset() {
        val defaults = MonitorAssistDefaults(100.0, MonitorCrushClipCompensation.QUARTER)
        val state = MonitorAssistState(defaults = defaults)
        assertEquals(100.0, state.zebraHighlightIRE)
        assertEquals(MonitorCrushClipCompensation.QUARTER, state.crushClipCompensation)

        state.setZebraHighlight(ire = 80.0)
        state.setCompensation(MonitorCrushClipCompensation.ONE)
        state.resetSettings(MonitorAssistTool.ZEBRA)
        assertEquals(100.0, state.zebraHighlightIRE)
        state.resetSettings(MonitorAssistTool.HISTO)
        assertEquals(MonitorCrushClipCompensation.QUARTER, state.crushClipCompensation)
        state.setCompensation(MonitorCrushClipCompensation.ONE)
        state.resetSettings(MonitorAssistTool.LIGHTS)
        assertEquals(MonitorCrushClipCompensation.QUARTER, state.crushClipCompensation)
    }

    /** A saved value always wins; only a value the snapshot lacks falls back to the declared default. */
    @Test
    fun savedValuesWinOverDeclaredDefaults() {
        val defaults = MonitorAssistDefaults(100.0, MonitorCrushClipCompensation.QUARTER)
        val saved = MonitorAssistState().apply {
            setZebraHighlight(ire = 99.0)
            setCompensation(MonitorCrushClipCompensation.ZERO)
        }.encoded()
        val restored = MonitorAssistState(encoded = saved, defaults = defaults)
        assertEquals(99.0, restored.zebraHighlightIRE)
        assertEquals(MonitorCrushClipCompensation.ZERO, restored.crushClipCompensation)

        val partial = org.json.JSONObject(saved).apply {
            remove("zebraHighlightIRE")
            remove("crushClipCompensation")
        }.toString()
        val filled = MonitorAssistState(encoded = partial, defaults = defaults)
        assertEquals(100.0, filled.zebraHighlightIRE)
        assertEquals(MonitorCrushClipCompensation.QUARTER, filled.crushClipCompensation)
    }
}
