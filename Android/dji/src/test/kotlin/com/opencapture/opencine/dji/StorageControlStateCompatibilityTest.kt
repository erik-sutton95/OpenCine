package com.opencapture.opencine.dji

import com.opencapture.opencine.core.CameraTimecode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class StorageControlStateCompatibilityTest {
    @Test fun originalDestructuringKeepsStorageModelTimecodeAndAudioPositions() {
        val reportedTimecode = CameraTimecode(1, 2, 3, 4)
        val state = PocketControlState(storageFreeMb = 2048, timecode = reportedTimecode)
        assertEquals(2048, state.component14())
        assertNull(state.component15())
        assertEquals(reportedTimecode, state.component16())
        assertNull(state.component17())
    }
}
