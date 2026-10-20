package com.opencapture.opencine.insta360.luna

import com.opencapture.opencine.insta360.shell.LunaScopeClip
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeClipSnapshot
import com.opencapture.opencine.media.ScopeExposureCeiling
import com.opencapture.opencine.media.ScopeTrafficLights
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** Luna I-Log preview clip per ISO (twin of Swift `LunaScopeClipTests`). */
class LunaScopeClipTest {
    @Test fun iLogClipFallsBelowTheNativeIsoAndHoldsAtAndAboveIt() {
        val ceiling = ScopeExposureCeiling(LunaScopeClip.PROFILE)
        val expected = mapOf(100 to 205, 160 to 220, 200 to 227, 400 to 248, 800 to 248, 1600 to 248, 3200 to 248, 6400 to 248)
        for ((iso, byte) in expected) assertEquals(byte, ceiling.clipByte(MonitorTransfer.ILOG, iso), "ISO $iso")
        assertEquals(400, LunaScopeClip.NATIVE_ISO)
        assertEquals(100, LunaScopeClip.LOWEST_ISO)
    }

    @Test fun aFrameAtTheIso100ClipIsFlaggedClipped() {
        val ceiling = ScopeExposureCeiling(LunaScopeClip.PROFILE)
        ceiling.syncISO(100)
        val clip = ceiling.clipByte(MonitorTransfer.ILOG)
        assertEquals(205, clip)
        val bins = IntArray(256).also { it[clip] = 1000 }
        assertTrue(ScopeTrafficLights.reading(bins, bins, bins, MonitorTransfer.ILOG, luma = bins,
            ceiling = ScopeClipSnapshot(MonitorTransfer.ILOG, clip)).anyClip)
        // The fixed 255 ceiling Luna used before never reached this frame.
        assertFalse(ScopeTrafficLights.reading(bins, bins, bins, MonitorTransfer.ILOG, luma = bins,
            ceiling = ScopeExposureCeiling()).anyClip)
    }

    @Test fun unreportedAutoIsoAssumesTheLowestIsoAndNeverKeepsAStaleManualOne() {
        val ceiling = ScopeExposureCeiling(LunaScopeClip.PROFILE)
        assertEquals(100, ceiling.resolvedISO())
        ceiling.syncISO(800)
        assertEquals(248, ceiling.clipByte(MonitorTransfer.ILOG))
        ceiling.syncISO(0)
        assertEquals(100, ceiling.resolvedISO())
        assertEquals(205, ceiling.clipByte(MonitorTransfer.ILOG))
        ceiling.syncISO(200)
        ceiling.syncISO(null)
        assertEquals(205, ceiling.clipByte(MonitorTransfer.ILOG))
    }

    @Test fun otherCurvesKeepTheirUncalibratedCeiling() {
        val ceiling = ScopeExposureCeiling(LunaScopeClip.PROFILE)
        assertEquals(255, ceiling.clipByte(MonitorTransfer.REC709, 100))
        assertEquals(setOf(MonitorTransfer.ILOG), LunaScopeClip.PROFILE.calibrations.keys)
    }
}
