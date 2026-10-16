package com.opencapture.opencine.appkit

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.opencine.media.MonitorLUTCube
import com.opencapture.opencine.media.MonitorTransfer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

class MonitorAssistRenderPlanTest {
    @Test fun scopeChangesDoNotRebuildTheNativePlaybackLook() {
        val assist = MonitorAssistState()
        val before = assist.renderPlan(MonitorTransfer.REC709)
        assist.toggle(MonitorAssistTool.WAVE)
        val after = assist.renderPlan(MonitorTransfer.REC709)
        assertEquals(before.playbackLookKey, after.playbackLookKey)
        assertTrue(after.scopeTap.waveform)
        assertTrue(after.scopeTap.includePoints)
    }
    @Test fun cleanPinsAndPlaybackVisibilityUseIndependentPlans() {
        val assist = MonitorAssistState(encoded = """{"tools":["WAVE","PEAK"]}""", pinnedNames = setOf("PEAK"),
            playbackNames = setOf("ZEBRA"))
        assist.clean = true
        val live = assist.renderPlan(MonitorTransfer.REC709)
        assertTrue(live.peaking); assertFalse(live.scopeTap.waveform)
        val playback = assist.renderPlan(MonitorTransfer.REC709, playback = true)
        assertFalse(playback.peaking); assertTrue(playback.zebraHighlightOn)
        assertTrue(playback.scopeTap.playback)
    }
    @Test fun inspectorSamplingRetiresWithoutChangingVisibleToolSelections() {
        val assist = MonitorAssistState()
        val owner = Any()
        assist.inspectorScopeDemand = MonitorInspectorScopeDemand(owner, MonitorAssistTool.WAVE, false)
        val inspected = assist.renderPlan(MonitorTransfer.REC709)
        assertTrue(inspected.scopeTap.inspectorOnly); assertTrue(inspected.scopeTap.waveform)
        assertFalse(assist.isOn(MonitorAssistTool.WAVE))
        assist.inspectorScopeDemand = null
        assertFalse(assist.renderPlan(MonitorTransfer.REC709).scopeTap.needsTap)
        assist.inspectorScopeDemand = MonitorInspectorScopeDemand(owner, MonitorAssistTool.FALSE, false)
        assertSame(owner, assist.renderPlan(MonitorTransfer.REC709).scopeTap.previewOwner)
    }
    @Test fun calibratedRasterAndSplitGatePreserveSourceValues() {
        val assist = MonitorAssistState(encoded = """{"tools":["LUT","FALSE","ZEBRA"],"splitComparison":true}""")
        val cube = MonitorLUTCube(2, ByteArray(32))
        val raster = MonitorAssistRasterValues(lut = cube, falseColorPaint = cube, falseColorWeight = cube,
            highlightCode = .83f, midtoneCode = .4f, midtoneHalf = .01f, noiseGateScale = 2f)
        val painted = assist.renderPlan(MonitorTransfer.REC709, 400, raster = raster)
        assertFalse(painted.splitComparison); assertTrue(painted.falseColorOn)
        assertEquals(.83f, painted.zebraHighlightCode); assertEquals(.01f, painted.zebraMidtoneHalf)
        assist.setFalseColor(MonitorFalseColorSelection.LIMITS)
        assertTrue(assist.renderPlan(MonitorTransfer.REC709, 400, raster = raster).splitComparison)
        assertEquals(400, painted.scopeTap.iso)
    }

    /** Product ruling 2026-10-16 (Swift twin: `curveToolsWaitForAKnownSourceCurveAndReturnOnTheirOwn`). */
    @Test fun anUnknownSourceCurveDrawsNoFalseColourOrZebraAndKeepsTheChoices() {
        val assist = MonitorAssistState(encoded = """{"tools":["FALSE","ZEBRA","PEAK"]}""")
        val cube = MonitorLUTCube(2, ByteArray(32))
        val raster = MonitorAssistRasterValues(falseColorPaint = cube, falseColorWeight = cube)
        val unknown = assist.renderPlan(null, 400, raster = raster)
        assertEquals(null, unknown.falseColorPaint); assertEquals(null, unknown.falseColorWeight)
        assertFalse(unknown.zebraHighlightOn || unknown.zebraMidtoneOn)
        assertTrue(unknown.peaking)
        assertTrue(assist.isOn(MonitorAssistTool.FALSE) && assist.isOn(MonitorAssistTool.ZEBRA))
        val known = assist.renderPlan(MonitorTransfer.DLOG, 400, raster = raster)
        assertSame(cube, known.falseColorPaint); assertTrue(known.zebraHighlightOn)
    }

    @Test fun onlyFalseColourAndZebraWaitForTheSourceCurve() {
        assertEquals(setOf(MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA),
            MonitorAssistTool.entries.filter { it.readsSourceCurve }.toSet())
        for (tool in MonitorAssistTool.entries) {
            assertEquals(!tool.readsSourceCurve, tool.offered(sourceTransfer = null), tool.name)
            assertTrue(tool.offered(sourceTransfer = MonitorTransfer.REC709), tool.name)
        }
    }
}
