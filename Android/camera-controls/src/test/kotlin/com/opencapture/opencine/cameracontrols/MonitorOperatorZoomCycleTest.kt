package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraSession
import com.opencapture.opencine.core.CommandReceipt
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.lunaLike
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A zoom cycle tap reaches the camera only through the common control's admission (A3-18). */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorOperatorZoomCycleTest {
    /** Every command offered to the session, admitted by it or not. */
    private class Offered(val fake: FakeCameraSession) : CameraSession by fake {
        val commands = mutableListOf<CameraCommand>()

        override suspend fun submit(command: CameraCommand): CommandReceipt {
            commands += command
            return fake.submit(command)
        }
    }

    private fun TestScope.bound(): Triple<FakeCameraSession, Offered, MonitorControlModel> {
        val camera = FakeCameraSession.lunaLike()
        camera.cameraReportsStatus()
        val session = Offered(camera)
        val control = MonitorControlModel(backgroundScope)
        control.bind(session)
        runCurrent()
        return Triple(camera, session, control)
    }

    private fun TestScope.settle() {
        advanceTimeBy(1_000)
        runCurrent()
    }

    @Test fun anAdmittedCycleTapIsOneCommonWrite() = runTest {
        val (camera, session, control) = bound()
        assertTrue(control.commitZoomCycle(2.0))
        assertEquals(2.0, control.state.value.pendingZoom)
        settle()
        assertEquals(1, session.commands.size)
        assertEquals(listOf("set ${SettingValue.Zoom(2.0)}"), camera.wire)
    }

    @Test fun aCycleTapUnderRevokedAuthorityWritesNothing() = runTest {
        val (camera, session, control) = bound()
        camera.setAuthority(ControlAuthority.ReadOnly)
        runCurrent()
        assertFalse(control.commitZoomCycle(2.0))
        assertNull(control.state.value.pendingZoom)
        settle()
        assertTrue(session.commands.isEmpty(), "${session.commands}")
        assertTrue(camera.wire.isEmpty())
    }

    @Test fun aCycleTapFromAStaleEpochWritesNothing() = runTest {
        val (camera, session, control) = bound()
        assertTrue(control.commitZoomCycle(2.0))
        // The link is replaced inside the coalescing window: the tap's epoch is gone.
        camera.completeAttempt(camera.loseLink())
        runCurrent()
        settle()
        assertTrue(session.commands.isEmpty(), "${session.commands}")
        assertTrue(camera.wire.isEmpty())
    }
}
