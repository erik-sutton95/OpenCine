package com.opencapture.opencine.vocabulary

import com.opencapture.opencine.media.MonitorTransfer
import kotlin.test.Test
import kotlin.test.assertEquals

class MonitorTransferColorModeTest {
    @Test fun everyCurveComesBackFromItsColorMode() {
        for (transfer in MonitorTransfer.entries) assertEquals(transfer, MonitorTransfer.fromColorMode(transfer.colorMode))
        assertEquals(CameraCommands.COLOR_ILOG, MonitorTransfer.ILOG.colorMode)
    }

    @Test fun otherCodesShowRec709() {
        for (code in listOf(CameraCommands.COLOR_NORMAL10, CameraCommands.COLOR_DOLBY_VISION, -1)) {
            assertEquals(MonitorTransfer.REC709, MonitorTransfer.fromColorMode(code))
        }
    }
}
