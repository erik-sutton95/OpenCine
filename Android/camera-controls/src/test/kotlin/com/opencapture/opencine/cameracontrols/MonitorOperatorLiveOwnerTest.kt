package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorJoystickSize
import com.opencapture.monitorui.MonitorRect
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.appkit.MonitorCapturePreferences
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorInteractionContext
import com.opencapture.opencine.appkit.MonitorInteractionLifecycle
import com.opencapture.opencine.core.*
import com.opencapture.opencine.core.testing.FakeCameraSession
import com.opencapture.opencine.core.testing.lunaLike
import com.opencapture.opencine.vocabulary.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.*

/** SIMULATED releases cross the same source/lifetime seam as both production operator surfaces. */
@OptIn(ExperimentalCoroutinesApi::class)
class MonitorOperatorLiveOwnerTest {
    @Test fun aReadOnlyTypedFocusKeepsItsReadoutAndRefusesTheHeldEditor() = runTest {
        val host = Reports()
        val original = FakeCameraSession.lunaLike()
        val descriptor = SettingDescriptor(SettingKey.FOCUS_MODE,
            domain = SettingDomain(listOf(SettingValue.FocusMode(FocusMode.SINGLE))))
        val mode = original.behavior.modes.getValue(0x01).copy(descriptors = listOf(descriptor), unsupported = emptySet())
        val camera = FakeCameraSession(original.behavior.copy(modes = mapOf(0x01 to mode)),
            original.device.copy(settings = mapOf(SettingKey.FOCUS_MODE to SettingValue.FocusMode(FocusMode.SINGLE))))
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val source = host.source(control)
        val lifetime = CaptureQuickLifetime().also { it.update(true) }
        val held = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        host.controls = host.controls.restricting(mapOf(ControlFamily.FOCUS to
            ControlStatus(SupportStatus.SUPPORTED, SettingAccess.READ_ONLY)))
        assertTrue(host.controls.focus.isShown)
        assertEquals("AF-S", source.readout(LiveSheet.FOCUS, host.status, host.status.focusLabel))
        source.release(LiveSheet.FOCUS, held, "Lock", lifetime, true)
        assertTrue(host.commits.isEmpty(), "A held writable editor cannot outlive read-only access")
        assertNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
    }

    @Test fun emulatedAngleCannotDisplayRetainedLegacyValuesWithoutTheCommonSource() = runTest {
        val host = Reports()
        host.status = host.status.copy(shutterDenom = 50, fps = 25)
        host.capturePreferences = host.capturePreferences.copy(shutterUsesAngle = true)
        val control = MonitorControlModel(backgroundScope)
        val source = host.source(control)
        assertNull(control.state.value.snapshot)
        assertEquals(50, host.status.shutterDenom, "The legacy facade deliberately retains its old report")
        assertEquals("--", source.readout(LiveSheet.SHUTTER, host.status, "180°"),
            "The emulated angle requires the current common shutter and recording cadence")
        assertTrue(host.commits.isEmpty())
    }

    @Test fun nativeFocusStrategiesRemainVisibleBesideTheCommonBaseMode() = runTest {
        val host = Reports()
        val camera = ReportedCamera()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val source = host.source(control)
        for ((strategy, label) in listOf(1 to "Showcase", 2 to "Lock", 3 to "Priority")) {
            host.status = host.status.copy(focusMode = CameraCommands.FOCUS_CONTINUOUS, focusTrack = strategy)
            assertEquals(label, source.readout(LiveSheet.FOCUS, host.status, host.status.focusLabel))
            assertEquals(label, source.quick(LiveSheet.FOCUS, host.status)?.selection)
            assertEquals(listOf("AF-S", "AF-C", "Showcase", "Lock", "Priority"), source.quick(LiveSheet.FOCUS, host.status)?.options)
        }
        host.status = host.status.copy(focusMode = -1, focusTrack = -1)
        assertEquals("--", source.readout(LiveSheet.FOCUS, host.status, host.status.focusLabel))
        assertTrue(host.commits.isEmpty(), "Reading native choices never sends a command")
    }

    @Test fun commonFocusReadoutWinsOverContradictoryNativePresentation() = runTest {
        val host = Reports()
        val original = FakeCameraSession.lunaLike()
        val descriptor = SettingDescriptor(SettingKey.FOCUS_MODE, domain = SettingDomain(listOf(
            SettingValue.FocusMode(FocusMode.SINGLE), SettingValue.FocusMode(FocusMode.CONTINUOUS))))
        val mode = original.behavior.modes.getValue(0x01).copy(descriptors = listOf(descriptor), unsupported = emptySet())
        val camera = FakeCameraSession(original.behavior.copy(modes = mapOf(0x01 to mode)),
            original.device.copy(settings = mapOf(SettingKey.FOCUS_MODE to SettingValue.FocusMode(FocusMode.CONTINUOUS))))
        camera.cameraReportsStatus()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val source = host.source(control)
        assertEquals(SettingValue.FocusMode(FocusMode.CONTINUOUS), control.state.value.snapshot?.value(SettingKey.FOCUS_MODE)?.value)
        assertEquals("AF-S", host.status.focusLabel, "The native fixture is deliberately contradictory")
        assertEquals("AF-C", source.readout(LiveSheet.FOCUS, host.status, host.status.focusLabel))
        assertTrue(host.commits.isEmpty(), "Formatting never writes the camera")
    }

    @Test fun nativePauseResumePhaseAndRemountRejectOldHeldPointers() = runTest {
        val host = Reports()
        val control = MonitorControlModel(backgroundScope)
        val source = host.source(control)
        val lifetime = CaptureQuickLifetime().also { it.update(true) }
        val beforePause = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        lifetime.update(false)
        lifetime.update(true)
        source.release(LiveSheet.FOCUS, beforePause, "Lock", lifetime, true)
        val beforePhase = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        lifetime.invalidate()
        source.release(LiveSheet.FOCUS, beforePhase, "Lock", lifetime, true)
        val beforeRemount = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        val remounted = CaptureQuickLifetime().also { it.update(true) }
        source.release(LiveSheet.FOCUS, beforeRemount, "Lock", remounted, true)
        assertTrue(host.commits.isEmpty())
        source.release(LiveSheet.FOCUS, requireNotNull(source.quick(LiveSheet.FOCUS, host.status, remounted)),
            "Lock", remounted, true)
        assertEquals(listOf<CaptureSetting>(CaptureSetting.Focus("Lock")), host.commits)
        assertEquals(0, host.refreshes)
        assertEquals(0, host.preferenceWrites)
    }

    @Test fun busyReportChangeAndLostCapabilityRefuseReleaseBeforeNativeCommit() = runTest {
        val host = Reports()
        val source = host.source(MonitorControlModel(backgroundScope))
        val lifetime = CaptureQuickLifetime().also { it.update(true) }
        val held = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        host.busy = true
        source.release(LiveSheet.FOCUS, held, "Lock", lifetime, true)
        host.busy = false
        host.status = host.status.copy(focusMode = CameraCommands.FOCUS_CONTINUOUS, focusTrack = 1)
        source.release(LiveSheet.FOCUS, held, "Lock", lifetime, true)
        val current = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        host.controls = host.controls.copy(focus = ControlCapability.unsupported())
        source.release(LiveSheet.FOCUS, current, "Lock", lifetime, true)
        assertNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        assertTrue(host.commits.isEmpty())
        host.controls = host.controls.copy(focus = ControlCapability.supported())
        source.release(LiveSheet.FOCUS, requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime)),
            "Lock", lifetime, true)
        assertEquals(listOf<CaptureSetting>(CaptureSetting.Focus("Lock")), host.commits)
    }

    @Test fun replacementAndRebindingCannotMoveHeldIsoToTheSuccessor() = runTest {
        val first = ReportedCamera()
        val successor = ReportedCamera()
        val host = Reports()
        val control = MonitorControlModel(backgroundScope)
        val source = host.source(control)
        val lifetime = CaptureQuickLifetime().also { it.update(true) }
        control.bind(first)
        val old = requireNotNull(source.quick(LiveSheet.ISO, host.status, lifetime))
        assertEquals("100", old.selection)
        control.bind(successor)
        source.release(LiveSheet.ISO, old, "200", lifetime, true)
        assertTrue(control.state.value.pending.isEmpty())
        val beforeRebind = requireNotNull(source.quick(LiveSheet.ISO, host.status, lifetime))
        control.unbind()
        control.bind(successor)
        source.release(LiveSheet.ISO, beforeRebind, "200", lifetime, true)
        assertTrue(control.state.value.pending.isEmpty())
        source.release(LiveSheet.ISO, requireNotNull(source.quick(LiveSheet.ISO, host.status, lifetime)),
            "200", lifetime, true)
        advanceTimeBy(120)
        runCurrent()
        assertTrue(first.fake.wire.isEmpty())
        assertEquals(listOf("set ${iso(200)}"), successor.fake.wire)
        assertTrue(host.commits.isEmpty(), "Common ISO crosses Core, not the native index adapter")
    }

    /**
     * Behavior audit PAA-221: holding the WB tile in Custom scrubbed Kelvin only in the standalone
     * apps; leaving Custom for Auto took the popup, so the hold drum offers no "Auto" detent.
     */
    @Test fun customWhiteBalanceHoldDrumScrubsKelvinOnly() = runTest {
        val host = Reports()
        host.status = host.status.copy(wbMode = CameraCommands.WB_CUSTOM, wbKelvin = 5600)
        val control = MonitorControlModel(backgroundScope)
        control.bind(whiteBalanceCamera())
        val quick = requireNotNull(host.source(control).quick(LiveSheet.WB, host.status))
        assertEquals(listOf("3200K", "5600K"), quick.options)
        assertTrue(quick.enabled)
    }

    /**
     * Behavior audit PAA-204: the ISO hold drum starred the log curve's native ISO (1600 in D-Log2)
     * in the standalone apps, also when the drum comes from the common ISO field.
     */
    @Test fun commonIsoHoldDrumStarsTheNativeIso() = runTest {
        val host = Reports()
        val control = MonitorControlModel(backgroundScope)
        control.bind(ReportedCamera())
        val quick = requireNotNull(host.source(control).quick(LiveSheet.ISO, host.status))
        assertEquals(listOf("100", "200", "400", "1600"), quick.options)
        assertEquals(setOf("1600"), quick.marked)
    }

    @Test fun removedThenRestoredDescriptorStillRetiresTheOriginalRelease() = runTest {
        val camera = ReportedCamera()
        val host = Reports()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val source = host.source(control)
        val lifetime = CaptureQuickLifetime().also { it.update(true) }
        val held = requireNotNull(source.quick(LiveSheet.ISO, host.status, lifetime))
        camera.fake.cameraSwitchesMode(0x02)
        runCurrent()
        assertFalse(requireNotNull(source.quick(LiveSheet.ISO, host.status, lifetime)).enabled)
        camera.fake.cameraSwitchesMode(0x01)
        runCurrent()
        source.release(LiveSheet.ISO, held, "200", lifetime, true)
        advanceTimeBy(120)
        runCurrent()
        assertTrue(camera.fake.wire.isEmpty())
        assertTrue(control.state.value.pending.isEmpty())
        source.release(LiveSheet.ISO, requireNotNull(source.quick(LiveSheet.ISO, host.status, lifetime)),
            "200", lifetime, true)
        advanceTimeBy(120)
        runCurrent()
        assertEquals(listOf("set ${iso(200)}"), camera.fake.wire)
    }

    @Test fun coverReturnAndRotationRetireReadoutsWithoutClosingOrCommandingTheCamera() = runTest {
        val camera = ReportedCamera()
        val host = Reports()
        val control = MonitorControlModel(backgroundScope)
        control.bind(camera)
        val source = host.source(control)
        val lifetime = CaptureQuickLifetime().also { it.update(true) }
        val state = MonitorOperatorLiveState()
        val lifecycle = MonitorInteractionLifecycle()
        val active = MonitorInteractionContext(camera = camera.id)
        state.apply(lifecycle.update(active), source)
        val beforeCover = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        state.open(LiveSheet.ISO, host.status)
        state.topQuickActive = true
        state.apply(lifecycle.update(active.copy(covered = true)), source)
        state.apply(lifecycle.update(active), source)
        source.release(LiveSheet.FOCUS, beforeCover, "Lock", lifetime, true)
        assertEquals(LiveSheet.ISO, state.sheet, "The cover keeps the open picker for the return")
        assertFalse(state.topQuickActive)
        val beforeRotation = requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime))
        state.open(LiveSheet.WB, host.status)
        state.stripQuickActive = true
        state.apply(lifecycle.update(active.copy(orientationRevision = 1)), source)
        source.release(LiveSheet.FOCUS, beforeRotation, "Lock", lifetime, true)
        assertEquals(LiveSheet.WB, state.sheet, "Rotation retires held input, preserving the persistent editor")
        assertFalse(state.stripQuickActive)
        assertEquals(0L, state.paletteRevision, "A cover and a turn keep the assist palette as it was")
        assertTrue(host.commits.isEmpty())
        assertTrue(camera.fake.wire.isEmpty())
        assertEquals(0, camera.closes)
        source.release(LiveSheet.FOCUS, requireNotNull(source.quick(LiveSheet.FOCUS, host.status, lifetime)),
            "Lock", lifetime, true)
        assertEquals(listOf<CaptureSetting>(CaptureSetting.Focus("Lock")), host.commits)
    }

    @Test fun reportedChoicesAndExplicitNativeEvRouteDoNotInventAudioOrFocus() = runTest {
        val host = Reports()
        val control = MonitorControlModel(backgroundScope)
        val source = host.source(control)
        assertNull(source.quick(LiveSheet.AUDIO, host.status))
        assertEquals(listOf("AF-S", "AF-C", "Showcase", "Lock", "Priority"), source.quick(LiveSheet.FOCUS, host.status)?.options)
        host.status = host.status.copy(focusMode = -1, focusTrack = -1)
        assertEquals("", source.quick(LiveSheet.FOCUS, host.status)?.selection)
        host.controls = host.controls.copy(focus = ControlCapability.unsupported())
        assertNull(source.quick(LiveSheet.FOCUS, host.status))
        host.status = host.status.copy(expoMode = CameraCommands.EXPO_AUTO, evComp = EvComp.ZERO.rawValue)
        assertFalse(requireNotNull(source.quick(LiveSheet.SHUTTER, host.status)).enabled)
        val native = host.source(control, nativeEv = true)
        assertEquals("0.0", native.quick(LiveSheet.SHUTTER, host.status)?.selection)
        assertTrue(requireNotNull(native.quick(LiveSheet.SHUTTER, host.status)).enabled)
        host.capturePreferences = host.capturePreferences.copy(facePriorityExposure = true)
        assertFalse(requireNotNull(native.quick(LiveSheet.SHUTTER, host.status)).enabled)
    }

    @Test fun portraitFramingKeepsScopesAboveCaptureAndClearOfTheExpandedAssistRail() {
        val assist = MonitorAssistState()
        val viewport = MonitorOperatorViewport(390f, 844f, 0f, 0f, 47f, 34f, 1f, true)
        val fit = monitorOperatorLiveLayout(viewport, assist, { true }, PortraitFeedAspect.FIT_16X9,
            16f / 9f, false, MonitorJoystickSize.MEDIUM, false)
        assertEquals(390f, fit.pictureContent.width)
        assertEquals(219.375f, fit.pictureContent.height)
        assertTrue(fit.scopePlacement.maxY <= fit.layout.capture.minY)
        val fill = monitorOperatorLiveLayout(viewport, assist, { true }, PortraitFeedAspect.FILL,
            16f / 9f, false, MonitorJoystickSize.MEDIUM, false)
        assertTrue(fill.pictureContent.width > viewport.width)
        assertEquals(viewport.width / 2f, fill.pictureContent.midX)
        assertTrue(fill.scopePlacement.minX > fit.scopePlacement.minX)
        assist.toggle(MonitorAssistTool.DESQ)
        val desqueezed = monitorOperatorLiveLayout(viewport, assist, { true }, PortraitFeedAspect.FILL,
            16f / 9f, false, MonitorJoystickSize.MEDIUM, false)
        assertTrue(desqueezed.pictureContent.width <= viewport.width)
        assertTrue(desqueezed.pictureContent.height < fit.pictureContent.height)
    }

    @Test fun landscapeScopesClearRealResetAndSystemControlsWhileVerticalPicturesRemainPillarboxed() {
        val assist = MonitorAssistState()
        val viewport = MonitorOperatorViewport(844f, 390f, 47f, 0f, 0f, 0f, 1f, true)
        val ordinary = monitorOperatorLiveLayout(viewport, assist, { true }, PortraitFeedAspect.FIT_16X9,
            16f / 9f, false, MonitorJoystickSize.MEDIUM, false)
        val reset = monitorOperatorLiveLayout(viewport, assist, { true }, PortraitFeedAspect.FIT_16X9,
            16f / 9f, false, MonitorJoystickSize.MEDIUM, true)
        assertEquals(ordinary.layout.settings.minX - 6f, ordinary.scopePlacement.maxX)
        assertTrue(reset.scopePlacement.minY >= reset.layout.focusReset.maxY)
        assertTrue(reset.scopePlacement.minY > ordinary.scopePlacement.minY)
        val vertical = monitorOperatorLiveLayout(viewport.copy(width = 390f, height = 844f), assist,
            { true }, PortraitFeedAspect.FILL, 9f / 16f, true, MonitorJoystickSize.MEDIUM, false)
        assertEquals(9f / 16f, vertical.pictureContent.width / vertical.pictureContent.height, 0.0001f)
        assertEquals(195f, vertical.pictureContent.midX)
    }

    private class Reports : CaptureSheetHost {
        var status = CameraStatus(expoMode = CameraCommands.EXPO_MANUAL, shootingMode = CameraCommands.SHOOT_VIDEO,
            colorMode = CameraCommands.COLOR_DLOG2, iso = 100, isoIndex = 1,
            focusMode = CameraCommands.FOCUS_SINGLE, focusTrack = 0)
        var busy = false
        var controls = ControlCapabilities(focus = ControlCapability.supported())
        var refreshes = 0
        var preferenceWrites = 0
        val commits = mutableListOf<CaptureSetting>()
        override val camera: CameraModel? = null
        override val labelProfile = CameraLabelProfile.standard
        override var capturePreferences = MonitorCapturePreferences(false, false, false, 180.0)
        private val native = object : CaptureSessionState {
            override val aeLocked = false
            override val awbLockKelvin: Int? = null
            override val awbLockOffered = false
            override val formatPinned = false
            override val controlCapabilities get() = controls
        }
        fun source(control: MonitorControlModel, nativeEv: Boolean = false) = MonitorOperatorCaptureSource(
            this, control, MutableStateFlow(true), { status }, { native }, { true }, { busy }, nativeEv, { false }, {})
        override fun captureField(sheet: LiveSheet, expoMode: Int): MonitorCaptureField? = null
        @Composable override fun captureSessionState(status: CameraStatus): CaptureSessionState = native
        override fun updateCapturePreferences(value: MonitorCapturePreferences) { capturePreferences = value; preferenceWrites++ }
        override fun commit(setting: CaptureSetting, field: MonitorCaptureField?, status: CameraStatus) { commits += setting }
        override suspend fun refresh(what: CaptureRefresh) { refreshes++ }
        @Composable override fun CommonDrum(sheet: LiveSheet, status: CameraStatus, field: MonitorCaptureField?,
            enabled: Boolean, wheel: CaptureWheelState) = Unit
    }

    /** The test adapter counts closing; camera behavior stays in the shared manual-clock fixture. */
    private class ReportedCamera(val fake: FakeCameraSession = isoCamera()) : CameraSession by fake {
        var closes = 0
        override suspend fun close(reason: SessionCloseReason) { closes++; fake.close(reason) }
        override fun closeNow(reason: SessionCloseReason) { closes++; fake.closeNow(reason) }
    }

    companion object {
        private fun iso(value: Int) = SettingValue.Iso(ISOValue.Manual(value))
        private fun whiteBalanceCamera(): FakeCameraSession {
            val original = FakeCameraSession.lunaLike()
            val kelvin = { k: Int -> SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(k)) }
            val mode = original.behavior.modes.getValue(0x01).copy(
                descriptors = listOf(SettingDescriptor(SettingKey.WHITE_BALANCE, domain = SettingDomain(listOf(
                    SettingValue.WhiteBalance(WhiteBalanceValue.Auto), kelvin(3200), kelvin(5600))))),
                unsupported = emptySet(),
            )
            return FakeCameraSession(original.behavior.copy(modes = mapOf(0x01 to mode)),
                original.device.copy(settings = mapOf(SettingKey.WHITE_BALANCE to kelvin(5600))))
                .also { it.cameraReportsStatus() }
        }
        private fun isoCamera(): FakeCameraSession {
            val original = FakeCameraSession.lunaLike()
            val mode = original.behavior.modes.getValue(0x01).copy(
                descriptors = listOf(SettingDescriptor(SettingKey.ISO,
                    domain = SettingDomain(listOf(iso(100), iso(200), iso(400), iso(1600))))),
                unsupported = emptySet(),
            )
            val withoutIso = mode.copy(descriptors = emptyList(), unsupported = setOf(SettingKey.ISO))
            return FakeCameraSession(original.behavior.copy(modes = mapOf(0x01 to mode, 0x02 to withoutIso)),
                original.device.copy(settings = mapOf(SettingKey.ISO to iso(100))))
                .also { it.cameraReportsStatus() }
        }
    }
}
