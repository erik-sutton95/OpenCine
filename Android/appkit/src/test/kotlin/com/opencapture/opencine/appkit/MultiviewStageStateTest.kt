package com.opencapture.opencine.appkit

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MultiviewStageStateTest {
    @Test fun presentationPreferencesSurviveRelaunch() {
        var saved: MultiviewStagePreferences? = null
        val state = MultiviewStageState(4)
        state.attachPersistence({ saved }) { saved = it; true }
        state.layout = MultiviewStageLayout.GRID
        state.selected = 2
        state.fill = true
        state.clean = true
        state.toolsExpanded = true
        state.toolUsage = state.toolUsage.recording("FIT", 100.0)
        val data = requireNotNull(saved).encode()
        val restored = MultiviewStageState(4)
        restored.attachPersistence({ MultiviewStagePreferences.decode(data) }) { error("Loading must not write") }
        assertEquals(state.preferences, restored.preferences)
        assertEquals(1, restored.toolUsage.counts["FIT"])
    }

    @Test fun legacyPresentationCannotOverwriteNewerCommonPreferences() {
        val state = MultiviewStageState(4)
        state.attachPersistence({ MultiviewStagePreferences(MultiviewStageLayout.GRID, 2, true) }) { true }
        state.importLegacy(MultiviewStagePreferences())
        assertEquals(MultiviewStageLayout.GRID, state.layout)
        assertEquals(2, state.selected)
        assertTrue(state.fill)
    }

    @Test fun failedSaveKeepsLiveStateAndPreviousStoredPreferences() {
        val stored = MultiviewStagePreferences(MultiviewStageLayout.GRID)
        val state = MultiviewStageState(4)
        state.attachPersistence({ stored }) { false }
        state.fill = true
        assertTrue(state.fill)
        val restored = MultiviewStageState(4)
        restored.attachPersistence({ stored }) { false }
        assertFalse(restored.fill)
        assertEquals(MultiviewStageLayout.GRID, restored.layout)
    }

    @Test fun qualifiedSlotCountBoundsRestoredAndEditedSelection() {
        val state = MultiviewStageState(2)
        state.attachPersistence({ MultiviewStagePreferences(selected = 8) }) { true }
        assertEquals(1, state.selected)
        state.selected = -4
        assertEquals(0, state.selected)
    }

    @Test fun missingCommonFieldsDecodeWithCompatibleDefaults() {
        val value = requireNotNull(MultiviewStagePreferences.decode("""{"layout":"2 × 2 grid","selected":2}"""))
        assertEquals(MultiviewStageLayout.GRID, value.layout)
        assertEquals(2, value.selected)
        assertFalse(value.fill || value.clean || value.toolsExpanded)
        assertTrue(value.toolUsage.counts.isEmpty())
    }

    @Test fun closeCopyUsesOnlyTheTypedRestoreFact() {
        assertEquals("Close Multiview? Recording continues.", MultiviewNetworkRestore.NONE.closeQuestion)
        assertEquals("Close Multiview and return cameras to their own Wi-Fi? Recording continues.",
            MultiviewNetworkRestore.CAMERA_NETWORKS.closeQuestion)
        assertEquals("Close monitoring", MultiviewNetworkRestore.CLOSE_ACTION)
    }
}
