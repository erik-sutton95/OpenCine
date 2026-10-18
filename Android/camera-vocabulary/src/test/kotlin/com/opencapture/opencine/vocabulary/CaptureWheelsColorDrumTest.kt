package com.opencapture.opencine.vocabulary

import kotlin.test.Test
import kotlin.test.assertEquals

/** Twin of the Swift `theColorDrumKeepsTheReportedCurrentModeTheOfferedListLacks`. */
class CaptureWheelsColorDrumTest {
    private val offered = listOf(CameraCommands.COLOR_NORMAL to "Normal", CameraCommands.COLOR_HDR to "HDR")

    @Test
    fun theColorDrumKeepsTheReportedCurrentModeTheOfferedListLacks() {
        assertEquals(
            offered + (CameraCommands.COLOR_DLOG2 to "D-Log2"),
            CaptureWheels.colorDrum(offered, CameraCommands.COLOR_DLOG2, "pocket"),
        )
        assertEquals(offered, CaptureWheels.colorDrum(offered, CameraCommands.COLOR_HDR, "pocket"))
        assertEquals(offered, CaptureWheels.colorDrum(offered, -1, "pocket"))
        assertEquals(
            listOf(CameraCommands.COLOR_ILOG to "I-Log"),
            CaptureWheels.colorDrum(emptyList(), CameraCommands.COLOR_ILOG, "pocket"),
        )
    }
}
