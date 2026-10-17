package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorFalseColorSelection
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.media.FeedEffectsRenderPlan
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLUTProfile
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.LutCatalog
import com.opencapture.opencine.vocabulary.LutCategory
import com.opencapture.opencine.vocabulary.LutEntry
import com.opencapture.opencine.vocabulary.LutLookSource
import com.opencapture.opencine.vocabulary.colorMode
import kotlin.test.*

/** Shared render-plan vectors: what each app's Swift core is asked to bake, and what the plan carries. */
class MonitorFeedEffectsPlansTest {
    private class RecordingPacker(override val isAvailable: Boolean = true) : MonitorFeedEffectsPacker {
        val calls = mutableListOf<String>()
        var scalars: FloatArray? = floatArrayOf(.83f, .4f, .01f, 2f)
        var failLuts = false
        private fun cube() = ByteArray(2 * 2 * 2 * 4) { 7 }

        override fun packImportedLut(utf8: ByteArray, exposureStops: Double, colorMode: Int): ByteArray? {
            calls += "lut:${utf8.decodeToString()}:$exposureStops:$colorMode"
            return if (failLuts) null else cube()
        }
        override fun packCreativeLut(title: String, exposureStops: Double, colorMode: Int): ByteArray? {
            calls += "creative:$title:$exposureStops:$colorMode"
            return cube()
        }
        override fun packFalseColorPaint(scaleOrdinal: Int, colorMode: Int, iso: Int): ByteArray? {
            calls += "paint:$scaleOrdinal:$colorMode:$iso"
            return cube()
        }
        override fun packFalseColorWeight(scaleOrdinal: Int, colorMode: Int, iso: Int): ByteArray? {
            calls += "weight:$scaleOrdinal:$colorMode:$iso"
            return cube()
        }
        override fun feedAssistScalars(colorMode: Int, iso: Int, highlightIRE: Float, midtoneIRE: Float): FloatArray? {
            calls += "scalars:$colorMode:$iso:$highlightIRE:$midtoneIRE"
            return scalars
        }
    }

    private val bytes: (LutLookSource) -> ByteArray? = { source ->
        when (source) {
            is LutLookSource.Asset -> source.fileName.encodeToByteArray()
            is LutLookSource.Custom -> "custom/${source.fileName}".encodeToByteArray()
            else -> null
        }
    }
    private val dlogProfile = CameraLUTProfile(automatic = mapOf(
        CameraCommands.COLOR_DLOG to LutLookSource.Asset("dlog.cube", title = "D-Log to Rec.709")))

    /** Only [tools] on: the default state arms the LUT, so it starts with that toggled off. */
    private fun assist(vararg tools: MonitorAssistTool) = MonitorAssistState().apply {
        toggle(MonitorAssistTool.LUT)
        tools.forEach { toggle(it) }
    }

    @Test fun falseColorOrdinalsFollowTheSwiftWire() {
        val vectors = listOf(
            MonitorFalseColorSelection.STOPS to listOf(0, 4),
            MonitorFalseColorSelection.IRE to listOf(1, 5),
            MonitorFalseColorSelection.LIMITS to listOf(2, 6),
            MonitorFalseColorSelection.SCENE_STOPS to listOf(3, 7),
        )
        for ((scale, ordinals) in vectors) {
            for ((rec709, ordinal) in listOf(false, true).zip(ordinals)) {
                assertEquals(ordinal, MonitorFeedEffectsPlans.falseColorOrdinal(scale, rec709))
                val packer = RecordingPacker()
                val state = assist(MonitorAssistTool.FALSE).apply { setFalseColor(scale); setFalseColorRead(rec709) }
                val plan = MonitorFeedEffectsPlans(packer).create(bytes, state, "off", CameraCommands.COLOR_DLOG, 800, dlogProfile)
                assertEquals(listOf("paint:$ordinal:${CameraCommands.COLOR_DLOG}:800", "weight:$ordinal:${CameraCommands.COLOR_DLOG}:800"),
                    packer.calls.filter { !it.startsWith("scalars") })
                assertNotNull(plan.falseColorPaint); assertNotNull(plan.falseColorWeight)
            }
        }
    }

    @Test fun manualConversionBakesExposureOnTheLookInput() {
        val profile = CameraLUTProfile(cameraLooks = listOf(
            LutEntry("ilogLook", "I-Log to Rec.709", LutCategory.CAMERA, "ilog.cube", MonitorTransfer.ILOG)))
        val packer = RecordingPacker()
        val state = assist(MonitorAssistTool.LUT).apply { updateLutExposure(1.0) }
        val plan = MonitorFeedEffectsPlans(packer).create(bytes, state, "ilogLook", CameraCommands.COLOR_DLOG, 800, profile)
        assertEquals(listOf("lut:ilog.cube:1.0:${MonitorTransfer.ILOG.colorMode}"), packer.calls.filter { it.startsWith("lut") })
        assertNotNull(plan.lutCube)
        // A look without a declared input bakes on the source curve.
        val source = RecordingPacker()
        MonitorFeedEffectsPlans(source).create(bytes, state, "officialDLog", CameraCommands.COLOR_DLOG, 800, profile)
        assertEquals(listOf("lut:DJI_Official_Pocket4P_DLog_Rec709_33.cube:1.0:${CameraCommands.COLOR_DLOG}"),
            source.calls.filter { it.startsWith("lut") })
    }

    @Test fun zebraAndGateScalarsComeFromTheCoreOnCameraCodes() {
        val packer = RecordingPacker()
        val state = assist(MonitorAssistTool.ZEBRA).apply { setZebraHighlight(ire = 95.0); setZebraMidtone(ire = 42.0) }
        val plan = MonitorFeedEffectsPlans(packer).create(bytes, state, "off", CameraCommands.COLOR_DLOG2, 1600, dlogProfile)
        assertEquals(listOf("scalars:${CameraCommands.COLOR_DLOG2}:1600:95.0:42.0"), packer.calls)
        assertEquals(.83f, plan.zebraHighlightCode)
        assertEquals(.4f, plan.zebraMidtoneCode)
        assertEquals(.01f, plan.zebraMidtoneHalf)
        assertEquals(1600, plan.scopeTap.iso)
    }

    @Test fun committedCustomGenerationRefreshesOnlyTheStoredLook() {
        val recording = RecordingPacker()
        val packer = object : MonitorFeedEffectsPacker by recording {
            override fun packImportedLut(utf8: ByteArray, exposureStops: Double, colorMode: Int): ByteArray {
                recording.packImportedLut(utf8, exposureStops, colorMode)
                return ByteArray(2 * 2 * 2 * 4) { utf8.first() }
            }
        }
        val state = assist(MonitorAssistTool.LUT)
        var document = byteArrayOf(7)
        val lookup: (LutLookSource) -> ByteArray? = { document }
        MonitorFeedEffectsPlans(packer).use { plans ->
            fun custom(generation: Long) = plans.create(lookup, state, "custom:Operator Look.cube",
                CameraCommands.COLOR_NORMAL, 800, dlogProfile, customLutGeneration = generation).lutCube
            val first = assertNotNull(custom(1))
            document = byteArrayOf(9)
            assertSame(first, custom(1), "A generation changes only on a committed library mutation")
            val replacement = assertNotNull(custom(2))
            assertNotSame(first, replacement)
            assertEquals(9, replacement.rgba.first().toInt())
            assertSame(replacement, custom(2), "An unchanged committed look stays cached")

            val official = plans.create(lookup, state, LutCatalog.AUTO, CameraCommands.COLOR_DLOG,
                800, dlogProfile, customLutGeneration = 2).lutCube
            document = byteArrayOf(11)
            assertSame(official, plans.create(lookup, state, LutCatalog.AUTO, CameraCommands.COLOR_DLOG,
                800, dlogProfile, customLutGeneration = 3).lutCube)
            val creative = plans.create(lookup, state, "creativeWarm", CameraCommands.COLOR_NORMAL,
                800, dlogProfile, customLutGeneration = 3).lutCube
            assertSame(creative, plans.create(lookup, state, "creativeWarm", CameraCommands.COLOR_NORMAL,
                800, dlogProfile, customLutGeneration = 4).lutCube)
            assertEquals(3, recording.calls.count { it.startsWith("lut:") })
            assertEquals(1, recording.calls.count { it.startsWith("creative:") })
        }
    }

    @Test fun cubesAreBakedOnceAndFailedBakesRetry() {
        val packer = RecordingPacker().apply { failLuts = true }
        val plans = MonitorFeedEffectsPlans(packer)
        val state = assist(MonitorAssistTool.LUT, MonitorAssistTool.FALSE)
        assertNull(plans.create(bytes, state, LutCatalog.AUTO, CameraCommands.COLOR_DLOG, 800, dlogProfile).lutCube)
        packer.failLuts = false
        assertNotNull(plans.create(bytes, state, LutCatalog.AUTO, CameraCommands.COLOR_DLOG, 800, dlogProfile).lutCube)
        plans.create(bytes, state, LutCatalog.AUTO, CameraCommands.COLOR_DLOG, 800, dlogProfile)
        assertEquals(2, packer.calls.count { it.startsWith("lut") })
        assertEquals(1, packer.calls.count { it.startsWith("paint") })
        // A changed ISO is a different false colour cube; the LUT stays cached.
        plans.create(bytes, state, LutCatalog.AUTO, CameraCommands.COLOR_DLOG, 1600, dlogProfile)
        assertEquals(2, packer.calls.count { it.startsWith("paint") })
        assertEquals(2, packer.calls.count { it.startsWith("lut") })
    }

    @Test fun vectorscopeOnLogWithoutALutReadsTheAutoConversion() {
        val packer = RecordingPacker()
        val state = assist(MonitorAssistTool.VECTOR)
        val plan = MonitorFeedEffectsPlans(packer).create(bytes, state, LutCatalog.AUTO, CameraCommands.COLOR_DLOG, 800, dlogProfile)
        assertNull(plan.lutCube)
        assertNotNull(plan.scopeTap.vectorLut)
        assertEquals(listOf("lut:dlog.cube:0.0:${CameraCommands.COLOR_DLOG}"), packer.calls.filter { it.startsWith("lut") })
    }

    @Test fun withoutTheSwiftCoreThePlanCarriesNoBakes() {
        val packer = RecordingPacker(isAvailable = false)
        val state = assist(MonitorAssistTool.LUT, MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA)
        val plan = MonitorFeedEffectsPlans(packer).create(bytes, state, "creativeMono", CameraCommands.COLOR_DLOG, 800, dlogProfile)
        assertTrue(packer.calls.isEmpty())
        assertNull(plan.lutCube); assertNull(plan.falseColorPaint)
    }

    @Test fun multiviewAutoLutCaptions() {
        val packer = RecordingPacker()
        val plans = MonitorFeedEffectsPlans(packer)
        assertEquals(FeedEffectsRenderPlan.IDENTITY to "Waiting for camera color", plans.multiviewAutoLut(bytes, true, -1, dlogProfile))
        assertEquals(FeedEffectsRenderPlan.IDENTITY to "Auto · no conversion needed",
            plans.multiviewAutoLut(bytes, true, CameraCommands.COLOR_NORMAL, dlogProfile))
        assertEquals(FeedEffectsRenderPlan.IDENTITY to "Auto · D-Log to Rec.709",
            plans.multiviewAutoLut(bytes, false, CameraCommands.COLOR_DLOG, dlogProfile))
        assertEquals(FeedEffectsRenderPlan.IDENTITY to "LUT unavailable",
            plans.multiviewAutoLut({ null }, true, CameraCommands.COLOR_DLOG, dlogProfile))
        val (plan, caption) = plans.multiviewAutoLut(bytes, true, CameraCommands.COLOR_DLOG, dlogProfile)
        assertEquals("Auto · D-Log to Rec.709", caption)
        assertNotNull(plan.lutCube)
        assertFalse(plan.peaking); assertFalse(plan.zebraHighlightOn)
    }

    /**
     * Product ruling 2026-10-16: an unknown source curve (DJI before its first colour report, Luna Dolby
     * Vision) bakes no false colour, draws no zebra and bakes the LUT without input exposure; the reported
     * curve brings them back with the operator's choices intact.
     */
    @Test fun anUnknownSourceCurveWithholdsCurveToolsUntilTheCameraReportsIt() {
        val state = assist(MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA, MonitorAssistTool.LUT).apply { updateLutExposure(1.0) }
        val packer = RecordingPacker()
        val plans = MonitorFeedEffectsPlans(packer)
        for (unknown in listOf(-1, CameraCommands.COLOR_DOLBY_VISION)) {
            val plan = plans.create(bytes, state, "creativeMono", unknown, 800, dlogProfile)
            assertNull(plan.falseColorPaint); assertNull(plan.falseColorWeight)
            assertFalse(plan.zebraHighlightOn || plan.zebraMidtoneOn)
            assertNotNull(plan.lutCube)
        }
        assertTrue(packer.calls.none { it.startsWith("paint") || it.startsWith("weight") })
        assertTrue(packer.calls.filter { it.startsWith("creative:") }.all { it.split(":")[2] == "0.0" }, "${packer.calls}")
        val known = plans.create(bytes, state, "creativeMono", CameraCommands.COLOR_DLOG, 800, dlogProfile)
        assertNotNull(known.falseColorPaint); assertTrue(known.zebraHighlightOn)
        assertTrue(packer.calls.any { it.startsWith("creative:") && it.split(":")[2] == "1.0" }, "${packer.calls}")
        assertTrue(state.isOn(MonitorAssistTool.FALSE) && state.isOn(MonitorAssistTool.ZEBRA))
    }

    /** The shared live palette offers false colour and zebra only with a known curve; the rest stay. */
    @Test fun theLivePaletteOffersCurveToolsOnlyWithAKnownCurve() {
        val unknown = vocabularyAssistTools(CameraStatus(), audio = true)
        assertFalse(MonitorAssistTool.FALSE in unknown || MonitorAssistTool.ZEBRA in unknown)
        assertTrue(MonitorAssistTool.PEAK in unknown && MonitorAssistTool.LUT in unknown)
        val known = vocabularyAssistTools(CameraStatus(colorMode = CameraCommands.COLOR_DLOG), audio = true)
        assertTrue(MonitorAssistTool.FALSE in known && MonitorAssistTool.ZEBRA in known)
        assertEquals(MonitorAssistTool.settingsCases.filter { it != MonitorAssistTool.AUDIO },
            vocabularyAssistTools(CameraStatus(colorMode = CameraCommands.COLOR_NORMAL), audio = false))
    }

    /** Settings explain the wait on the false colour and zebra cards and offer LUT exposure only with a curve. */
    @Test fun settingsExplainTheWaitAndTheLutPickerOffersExposureOnlyWithACurve() {
        for (tool in listOf(MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA)) {
            assertEquals(MonitorSettingsCopy.sourceCurveUnknown, assistCardUnavailableMessage(tool, null))
            assertNull(assistCardUnavailableMessage(tool, MonitorTransfer.DLOG))
        }
        assertNull(assistCardUnavailableMessage(MonitorAssistTool.WAVE, null))
        assertFalse(lutExposureOffered(-1))
        assertFalse(lutExposureOffered(CameraCommands.COLOR_DOLBY_VISION))
        assertTrue(lutExposureOffered(CameraCommands.COLOR_DLOG))
    }
}
