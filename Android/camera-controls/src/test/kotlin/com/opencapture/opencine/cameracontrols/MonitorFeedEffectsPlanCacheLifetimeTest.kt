package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLUTProfile
import kotlin.test.*

/** Draft only: real plan assembly and cache, not a mirror of either implementation. Native JNI is a separate gate. */
class MonitorFeedEffectsPlanCacheLifetimeTest {
    private class Packer : MonitorFeedEffectsPacker {
        override val isAvailable = true
        var paintCalls = 0
        var weightCalls = 0
        override fun packImportedLut(utf8: ByteArray, exposureStops: Double, colorMode: Int): ByteArray? = null
        override fun packCreativeLut(title: String, exposureStops: Double, colorMode: Int): ByteArray? = null
        override fun packFalseColorPaint(scaleOrdinal: Int, colorMode: Int, iso: Int): ByteArray {
            paintCalls++
            return ByteArray(1_048_576) { (10 + scaleOrdinal).toByte() }
        }
        override fun packFalseColorWeight(scaleOrdinal: Int, colorMode: Int, iso: Int): ByteArray {
            weightCalls++
            return ByteArray(1_048_576) { (20 + scaleOrdinal).toByte() }
        }
        override fun feedAssistScalars(colorMode: Int, iso: Int, highlightIRE: Float, midtoneIRE: Float) =
            floatArrayOf(.9f, .4f, .02f, 1f)
    }
    private fun state() = MonitorAssistState().apply {
        toggle(MonitorAssistTool.LUT)
        toggle(MonitorAssistTool.FALSE)
        setFalseColor(MonitorFalseColorSelection.IRE)
    }

    @Test fun realPlanOwnersCacheSeparatelyAndRetirementKeepsCurrentOwnerAndBorrowedPlans() {
        val packer = Packer()
        val live = MonitorFeedEffectsPlans(packer)
        val playback = MonitorFeedEffectsPlans(packer)
        val assist = state()
        val profile = CameraLUTProfile()
        fun read(plans: MonitorFeedEffectsPlans) = plans.create(
            { null }, assist, "off", CameraCommands.COLOR_DLOG, 800, profile)
        val livePlan = read(live)
        val playbackPlan = read(playback)
        assertEquals(2, packer.paintCalls); assertEquals(2, packer.weightCalls)
        assertEquals(64, assertNotNull(livePlan.falseColorPaint).size)
        assertSame(livePlan.falseColorPaint, read(live).falseColorPaint)
        assertSame(playbackPlan.falseColorPaint, read(playback).falseColorPaint)
        live.close()
        assertNull(read(live).falseColorPaint)
        assertSame(playbackPlan.falseColorPaint, read(playback).falseColorPaint)
        assertEquals(2, packer.paintCalls); assertEquals(2, packer.weightCalls)
        assertContentEquals(livePlan.falseColorPaint!!.rgba, playbackPlan.falseColorPaint!!.rgba)
        assertNotSame(livePlan.falseColorPaint!!.rgba, playbackPlan.falseColorPaint!!.rgba)
        playback.close()
    }
}
