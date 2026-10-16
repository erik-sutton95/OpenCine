package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.MonitorTransfer
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class MonitorTransferColorModeTest {
    @Test fun unknownLegacyCodesDoNotBecomeSourceCurveObservations() {
        for (code in listOf(-1, 999, CameraCommands.COLOR_DOLBY_VISION)) {
            assertNull(MonitorTransfer.knownFromColorMode(code))
            assertEquals(MonitorTransfer.REC709, MonitorTransfer.fromColorMode(code))
        }
        assertEquals(MonitorTransfer.ILOG, MonitorTransfer.knownFromColorMode(CameraCommands.COLOR_ILOG))
        assertEquals(MonitorTransfer.REC709, MonitorTransfer.knownFromColorMode(CameraCommands.COLOR_NORMAL10))
    }

    @Test fun everyCurveWithAColorModeComesBackFromIt() {
        val dji = MonitorTransfer.entries.filter { it.colorMode >= 0 }
        for (transfer in dji) assertEquals(transfer, MonitorTransfer.fromColorMode(transfer.colorMode))
        assertEquals(CameraCommands.COLOR_ILOG, MonitorTransfer.ILOG.colorMode)
        // Only the curves no DJI camera reports lack a colour code.
        assertEquals(
            setOf(MonitorTransfer.SRGB, MonitorTransfer.NLOG, MonitorTransfer.LOG3G10),
            MonitorTransfer.entries.toSet() - dji.toSet(),
        )
    }

    @Test fun otherCodesShowRec709() {
        for (code in listOf(CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DOLBY_VISION, -1)) {
            assertEquals(MonitorTransfer.REC709, MonitorTransfer.fromColorMode(code))
        }
    }
}
