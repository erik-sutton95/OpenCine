package com.opencapture.opencine.cameracontrols

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** SIMULATED source-owned metering: unknown and retired sources never toggle (twin of the Swift METER source). */
class MonitorOperatorMeteringTileTest {
    @Test fun unknownModeShowsThePlaceholderAndHasNoToggleTarget() {
        var toggles = 0
        val tile = MonitorOperatorMeteringTile(null) { toggles += 1 }
        assertEquals("--", tile.label)
        tile.perform()
        assertEquals(0, toggles)
    }

    @Test fun knownModeTogglesOnlyWhileItsSourceIsCurrent() {
        var toggles = 0
        var current = true
        val tile = MonitorOperatorMeteringTile(false, isCurrent = { current }) { toggles += 1 }
        assertEquals("Matrix", tile.label)
        assertEquals("Face", MonitorOperatorMeteringTile(true) {}.label)
        tile.perform()
        assertEquals(1, toggles)
        current = false
        tile.perform()
        assertTrue(toggles == 1, "A retired source does not toggle")
    }
}
