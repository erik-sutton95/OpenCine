package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.vocabulary.ConnectionPhase
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

/** Display's Edit view follows the presented monitor, as Swift's `editChrome` does, not the link phase. */
class OperatorChromeEditGateTest {
    private fun state(phase: ConnectionPhase, monitorPresented: Boolean) = OperatorSetupState(
        phase = phase, failure = null, colorMode = 0, network = null, cameraName = null, cameraFamily = null,
        layout = MonitorLayoutCapabilities(), monitorPresented = monitorPresented,
    )

    @Test fun aPresentedMonitorOffersEditViewBeforeTheLinkIsLive() {
        val begun = mutableListOf<MonitorDisplayMode>()
        val edit = assertNotNull(state(ConnectionPhase.IDLE, monitorPresented = true).chromeEdit { begun += it })
        edit(MonitorDisplayMode.CLEAN)
        assertEquals(listOf(MonitorDisplayMode.CLEAN), begun)
    }

    @Test fun aLiveLinkWithoutAPresentedMonitorOffersNoEditView() {
        assertNull(state(ConnectionPhase.LIVE, monitorPresented = false).chromeEdit {})
    }

    @Test fun aLiveLinkWithItsMonitorOffersEditView() {
        assertNotNull(state(ConnectionPhase.LIVE, monitorPresented = true).chromeEdit {})
    }
}
