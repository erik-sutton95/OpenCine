package com.opencapture.monitorui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Owner request 2026-10-31: the photo viewer shows the playback assist bar with every tool that
 * works on a still. Swift twin: MonitorAssistSelection.photoToolbarCases.
 */
class MonitorPhotoToolbarCasesTest {
    @Test fun aStillOffersThePlaybackBarInItsOrderWithoutClipOnlyTools() {
        val photo = MonitorAssistTool.photoToolbarCases
        assertEquals(MonitorAssistTool.playbackToolbarCases.filter { it in photo }, photo)
        for (tool in listOf(MonitorAssistTool.DESQ, MonitorAssistTool.PEAK, MonitorAssistTool.FALSE,
            MonitorAssistTool.ZEBRA, MonitorAssistTool.GUIDES, MonitorAssistTool.GRID, MonitorAssistTool.CROSS,
            MonitorAssistTool.MIRROR, MonitorAssistTool.WAVE, MonitorAssistTool.HISTO)) {
            assertTrue("$tool works on a still", tool in photo)
        }
        // The assist cubes convert a camera log curve; a still is display-referred Rec.709.
        assertFalse(MonitorAssistTool.LUT in photo)
        // A still has no sound, no exposure to change and no camera attitude.
        for (tool in listOf(MonitorAssistTool.AUDIO, MonitorAssistTool.ND, MonitorAssistTool.LEVEL, MonitorAssistTool.EV)) {
            assertFalse("$tool is clip or live only", tool in photo)
        }
    }

    @Test fun onlyPixelRemakingToolsNeedAStillRenderer() {
        assertEquals(setOf(MonitorAssistTool.PEAK, MonitorAssistTool.FALSE, MonitorAssistTool.ZEBRA),
            MonitorAssistTool.photoPictureTools)
        assertTrue(MonitorAssistTool.photoToolbarCases.containsAll(MonitorAssistTool.photoPictureTools))
    }
}
