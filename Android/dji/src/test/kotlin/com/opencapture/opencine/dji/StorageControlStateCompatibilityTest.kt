package com.opencapture.opencine.dji

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class StorageControlStateCompatibilityTest {
    @Test fun originalDestructuringKeepsStorageModelTimecodeAndAudioPositions() {
        val state = PocketControlState(storageFreeMb = 2048, timecode = "01:02:03:04")
        assertEquals(2048, state.component14())
        assertNull(state.component15())
        assertEquals("01:02:03:04", state.component16())
        assertNull(state.component17())
    }
}
