package com.opencapture.opencine.appkit

import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.snapshots.SnapshotStateObserver
import com.opencapture.monitorui.MonitorStatusPresentation
import com.opencapture.monitorui.MonitorTimecodeFormat
import com.opencapture.opencine.core.CameraTimecode
import com.opencapture.opencine.core.CameraTimecodeReading
import com.opencapture.opencine.core.Rational
import com.opencapture.opencine.core.SupportStatus
import com.opencapture.opencine.core.TimecodeCapability
import com.opencapture.opencine.core.TimecodePrecision
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.djiLike
import com.opencapture.opencine.core.testing.lunaLike
import com.opencapture.opencine.core.testing.nikonLike
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertNull
import kotlin.test.assertSame

/** A5-02, A5-03: one formatter follows the precision the source declares. SIMULATED sources; Swift `TimecodePrecisionTests`. */
@OptIn(ExperimentalCoroutinesApi::class)
class TimecodePrecisionTest {
    private val value = CameraTimecode(1, 2, 3, frames = 17)

    @Test fun framesShowOnlyUnderADeclaredFramePrecision() {
        val frames = TimecodePrecision.Frames(Rational(24))
        assertEquals("01:02:03:17", MonitorTimecodeFormat.label(value, frames))
        assertEquals("01:02:03", MonitorTimecodeFormat.label(value, TimecodePrecision.Seconds))
        assertEquals("01:02:03", MonitorTimecodeFormat.label(value, null), "an undeclared precision never shows a frame field")
        assertEquals("01:02:03", MonitorTimecodeFormat.label(CameraTimecodeReading(1, 2, 3), frames), "a missing frame count is never derived")
    }

    @Test fun dropFrameFollowsTheValueThenTheDeclaration() {
        val declared = TimecodePrecision.Frames(Rational(30000, 1001), dropFrame = true)
        assertEquals("01:02:03;17", MonitorTimecodeFormat.label(value, declared))
        assertEquals("01:02:03:17", MonitorTimecodeFormat.label(value.copy(dropFrame = false), declared))
    }

    /**
     * A5-13: the empty clock follows the declaration too: a frame-counting source keeps its frame
     * field, seconds and undeclared sources show seconds. No surface hard-codes one.
     */
    @Test fun placeholderFollowsTheDeclaredPrecision() {
        assertEquals("--:--:--:--", MonitorTimecodeFormat.placeholder(TimecodePrecision.Frames(Rational(25))))
        assertEquals("--:--:--", MonitorTimecodeFormat.placeholder(TimecodePrecision.Seconds))
        assertEquals("--:--:--", MonitorTimecodeFormat.placeholder(null))
        assertEquals("--:--:--:--", MonitorStatusPresentation(null, timecodePlaceholder = "--:--:--:--").clock)
        assertEquals("01:02:03", MonitorStatusPresentation(null, timecode = "01:02:03").clock)
    }

    @Test fun statusPlaceholderFollowsEachSourceDeclaration() = runTest {
        for ((camera, placeholder) in listOf(
            FakeCameraSession.djiLike() to "--:--:--",
            FakeCameraSession.nikonLike() to "--:--:--:--",
            FakeCameraSession.lunaLike() to "--:--:--",
        )) {
            camera.cameraReportsStatus()
            val control = MonitorControlModel(backgroundScope)
            control.bind(camera)
            assertEquals(placeholder, control.statusPresentation().timecodePlaceholder, camera.behavior.integration.rawValue)
        }
    }

    @Test fun capabilityKeepsPrecisionOnlyWhileSupported() {
        assertNull(TimecodeCapability(SupportStatus.UNKNOWN, TimecodePrecision.Seconds).precision)
        assertNull(TimecodeCapability.unsupported.precision)
        assertEquals(TimecodePrecision.Seconds, TimecodeCapability.supported(TimecodePrecision.Seconds).precision)
    }

    @Test fun statusClockFollowsEachSourceDeclaration() = runTest {
        for ((camera, label) in listOf(
            FakeCameraSession.djiLike() to "01:02:03",
            FakeCameraSession.nikonLike() to "10:00:00:00",
            FakeCameraSession.lunaLike() to "09:30:00",
        )) {
            camera.cameraReportsStatus()
            val control = MonitorControlModel(backgroundScope)
            control.bind(camera)
            assertEquals(label, control.statusPresentation().timecode, camera.behavior.integration.rawValue)
        }
    }

    @Test fun aTimecodeOnlyReportDoesNotReEmitTheSnapshot() = runTest {
        val camera = FakeCameraSession.nikonLike()
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        assertEquals(0, control.timecode.value?.frames)
        val reported = control.state.value
        var clock = 0
        val observer = SnapshotStateObserver { it() }
        observer.start()
        try {
            observer.observeReads("clock", { clock++ }) { control.statusPresentation() }
            camera.cameraReportsTimecode(CameraTimecode(10, 0, 0, 1)); runCurrent()
            Snapshot.sendApplyNotifications()
            assertEquals(1, clock, "the clock re-renders")
            assertEquals("10:00:00:01", control.statusPresentation().timecode)
            assertSame(reported, control.state.value, "a per-frame counter re-renders the clock only")
            camera.loseLink(); runCurrent()
            assertNotSame(reported, control.state.value, "any other change still emits")
        } finally {
            observer.stop()
            observer.clear()
        }
    }
}
