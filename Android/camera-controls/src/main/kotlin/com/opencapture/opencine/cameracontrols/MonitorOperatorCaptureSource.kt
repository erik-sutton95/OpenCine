package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.opencapture.monitorui.MonitorQuickControl
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.appkit.kelvinScrub
import com.opencapture.opencine.appkit.MonitorCapturePresentation
import com.opencapture.opencine.appkit.MonitorCaptureSelection
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.captureField
import com.opencapture.opencine.appkit.captureValue
import com.opencapture.opencine.appkit.commit
import com.opencapture.opencine.appkit.quickControl
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.CapabilityRevision
import com.opencapture.opencine.core.ControlEpoch
import com.opencapture.opencine.core.FocusMode
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.vocabulary.ApertureStrategy
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureSessionState
import com.opencapture.opencine.vocabulary.CaptureSetting
import com.opencapture.opencine.vocabulary.FocusTrackMode
import com.opencapture.opencine.vocabulary.FocusOption
import com.opencapture.opencine.vocabulary.ShutterAngle
import com.opencapture.opencine.vocabulary.VideoResolution
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect

/**
 * A native capture adapter supplies reports and its existing typed sheet host. This owner projects
 * the same choices into held readout previews and persistent sheets, and admits releases against
 * the captured Core source, native phase lifetime, and current report before any typed commit.
 */
public class MonitorOperatorCaptureSource(
    public val host: CaptureSheetHost,
    public val control: MonitorControlModel,
    public val phaseEvents: Flow<*>,
    private val readStatus: () -> CameraStatus,
    private val readSessionState: () -> CaptureSessionState,
    private val ready: () -> Boolean,
    private val busy: () -> Boolean,
    /** True only when EV uses the host's typed native route rather than the Core descriptor. */
    private val nativeExposureCompensation: Boolean = false,
    public val confirmRecording: () -> Boolean,
    public val takePhoto: () -> Unit,
) {
    public val isReady: Boolean get() = ready()
    private var presentationRevision: Long by mutableLongStateOf(0L)

    /** Retires held controls when a cover, editor, rotation, or source interrupts the surface. */
    public fun retirePresentation(): Unit { presentationRevision += 1L }

    public fun commonField(sheet: LiveSheet, status: CameraStatus): MonitorCaptureField? {
        val key = when (sheet) {
            LiveSheet.ISO -> if (readSessionState().controlCapabilities.nativeISO.ceiling == true && CaptureLists.shouldGetIsoLimit(status)) null else SettingKey.ISO
            LiveSheet.SHUTTER -> when {
                (nativeExposureCompensation && CaptureLists.isEvSheet(sheet, status.expoMode)) ||
                    control.state.value.snapshot?.exposureProgram?.value == com.opencapture.opencine.core.CameraExposureProgram.AUTOMATIC ->
                    if (nativeExposureCompensation || !host.captureRouting.commonExposureCompensation) null else SettingKey.EXPOSURE_COMPENSATION
                host.capturePreferences.shutterUsesAngle && !CameraCommands.isPhotoMode(status.shootingMode) -> null
                else -> SettingKey.SHUTTER
            }
            LiveSheet.WB -> if (status.wbMode == CameraCommands.WB_CUSTOM && readSessionState().awbLockKelvin == null)
                SettingKey.WHITE_BALANCE else null
            else -> null
        } ?: return null
        return control.captureField(key) ?: MonitorCaptureField(key,
            MonitorCapturePresentation.title(key).orEmpty(), null, emptyList(), null)
    }

    /** A format change or a shutter write still settling: the angle readout holds the operator's angle. */
    public val shutterAngleSettling: Boolean
        get() = readSessionState().formatPinned || control.state.value.pending[SettingKey.SHUTTER] != null ||
            control.frameRateSettling

    private fun angleShutter() = (control.captureValue(SettingKey.SHUTTER, host.captureReadoutSelection) as? SettingValue.Shutter)?.value
    private fun angleFrameRate() = (control.state.value.snapshot?.value(SettingKey.FRAME_RATE)?.value as? SettingValue.FrameRate)?.fps

    /** The shutter panel's subtitle: the tabs, or what the camera really makes for the held angle. */
    public fun shutterPanelSubtitle(base: String, status: CameraStatus): String {
        if (!host.capturePreferences.shutterUsesAngle || CameraCommands.isPhotoMode(status.shootingMode)) return base
        val achieved = CaptureNativeReadoutPresentation.shutterAngleAchieved(angleShutter(), angleFrameRate(),
            CaptureLists.shutterDenoms(status), host.capturePreferences.shutterAngleDegrees, shutterAngleSettling) ?: return base
        return "Angle · actual $achieved"
    }

    public fun readout(sheet: LiveSheet, status: CameraStatus, nativeLabel: String): String {
        val key = when (sheet) {
            LiveSheet.ISO -> SettingKey.ISO
            LiveSheet.SHUTTER -> when {
                (nativeExposureCompensation && CaptureLists.isEvSheet(sheet, status.expoMode)) ||
                    control.state.value.snapshot?.exposureProgram?.value == com.opencapture.opencine.core.CameraExposureProgram.AUTOMATIC -> {
                    if (nativeExposureCompensation || !host.captureRouting.commonExposureCompensation) return nativeLabel
                    SettingKey.EXPOSURE_COMPENSATION
                }
                host.capturePreferences.shutterUsesAngle && !CameraCommands.isPhotoMode(status.shootingMode) -> return CaptureNativeReadoutPresentation.shutterAngle(
                    angleShutter(), angleFrameRate(), CaptureLists.shutterDenoms(status),
                    host.capturePreferences.shutterAngleDegrees, shutterAngleSettling)
                else -> SettingKey.SHUTTER
            }
            LiveSheet.WB -> {
                if (readSessionState().awbLockKelvin != null) return nativeLabel
                SettingKey.WHITE_BALANCE
            }
            LiveSheet.FOCUS -> return CaptureNativeReadoutPresentation.focus(
                (control.captureValue(SettingKey.FOCUS_MODE, host.captureReadoutSelection) as? SettingValue.FocusMode)?.mode,
                FocusOption.resolve(status.focusMode, status.focusTrack))
            LiveSheet.APERTURE -> return CaptureNativeReadoutPresentation.aperture(
                (control.captureValue(SettingKey.APERTURE, host.captureReadoutSelection) as? SettingValue.Aperture)?.fNumber,
                status.apertureStrategy)
            else -> return nativeLabel
        }
        return control.captureValue(key, host.captureReadoutSelection)?.let(MonitorCapturePresentation::label) ?: "--"
    }

    public fun quick(sheet: LiveSheet, status: CameraStatus,
        lifetime: CaptureQuickLifetime? = null): MonitorQuickControl? {
        val state = readSessionState()
        val preferences = host.capturePreferences
        val body = host.camera?.name.orEmpty()
        val floor = host.camera?.captureProfile?.isoAutoRangeFloor
        val labels = host.labelProfile
        fun captured(value: MonitorQuickControl): MonitorQuickControl {
            val snapshot = control.state.value.snapshot
            return value.copy(identity = Source(this, snapshot?.session, snapshot?.epoch, snapshot?.capabilities?.revision, presentationRevision,
                lifetime, lifetime?.epoch ?: 0L, value.identity as? MonitorCaptureField
                    ?: if (sheet == LiveSheet.FOCUS) host.captureField(sheet, status.expoMode) else null))
        }
        host.nativeCaptureQuick(sheet, status)?.let { return captured(it) }
        commonField(sheet, status)?.let { common ->
            val field = if (sheet == LiveSheet.WB) common.kelvinScrub else common
            // The ISO drum stars the curve's native ISO whichever source owns it.
            val marked = if (sheet == LiveSheet.ISO) CaptureLists.isoMarkedLabels(status) else emptySet()
            return captured(field.quickControl().copy(marked = marked, enabled = field.isEditable &&
                (sheet != LiveSheet.SHUTTER || status.expoMode != CameraCommands.EXPO_AUTO || !preferences.facePriorityExposure)))
        }
        return when (sheet) {
            LiveSheet.ISO -> {
                val seat = IsoSheetLogic.reseat(status, body, floor, state.controlCapabilities.nativeISO.ceiling == true)
                captured(MonitorQuickControl(if (IsoSheetLogic.isAutoTab(status, seat.selectedMode))
                    IsoSheetLogic.autoLabels(status, body, floor, state.controlCapabilities.nativeISO.ceiling == true) else CaptureLists.isoDrumLabels(status),
                    seat.drumSelection, CaptureLists.isoMarkedLabels(status), context = "${status.colorMode}"))
            }
            LiveSheet.SHUTTER -> {
                val auto = CaptureLists.isEvSheet(sheet, status.expoMode)
                val angle = preferences.shutterUsesAngle && !auto && !CameraCommands.isPhotoMode(status.shootingMode)
                val selected = if (auto) CaptureLists.reseatEv(status).selection else
                    CaptureLists.reseatShutter(status, if (angle) 1 else 0, false, preferences.shutterAngleDegrees).selection
                captured(MonitorQuickControl(if (auto) CaptureLists.evLabels else if (angle) ShutterAngle.labels
                    else CaptureLists.shutterLabels(status), selected, enabled = !auto || !preferences.facePriorityExposure,
                    context = "${status.fps}:${status.availableShutterDenoms}:${status.expoMode}:$angle:${status.shootingMode}"))
            }
            LiveSheet.WB -> {
                val locked = state.awbLockKelvin != null
                captured(if (status.wbMode == CameraCommands.WB_CUSTOM && !locked)
                    MonitorQuickControl(CaptureLists.kelvinLabels, CaptureLists.wbDrumSelection(status),
                        context = "${CaptureLists.currentTint(status)}")
                else MonitorQuickControl(CaptureLists.wbModeRows(locked || state.awbLockOffered),
                    CaptureLists.wbModeRowSelected(status, locked),
                    context = "${status.wbMode}:${CaptureLists.currentKelvin(status)}:${CaptureLists.currentTint(status)}"))
            }
            LiveSheet.FOCUS -> if (!state.controlCapabilities.focus.isOffered) null
                else captured(captureQuickFocusControl(status, labels.focusLabels))
            LiveSheet.APERTURE -> if (!state.controlCapabilities.iris.isOffered) null else captured(MonitorQuickControl(
                CaptureLists.apertureLabels(status), ApertureStrategy.label(status.apertureStrategy).orEmpty()))
            LiveSheet.EXPO -> captured(MonitorQuickControl(CaptureLists.expoLabels(state.aeLocked),
                CaptureLists.expoSelectedLabel(status.expoMode, state.aeLocked) ?: CaptureLists.expoLabel(status.expoMode)))
            LiveSheet.AUDIO -> {
                val service = host.audioService
                val field = service?.fields?.firstOrNull()
                if (CameraCommands.isPhotoMode(status.shootingMode) || field == null) null
                else captured(MonitorQuickControl(field.choices.map { it.label }, field.observed?.label.orEmpty(),
                    enabled = field.isEditable, context = "${service.sourceID}:${field.id}"))
            }
            LiveSheet.FORMAT, LiveSheet.COLOR, LiveSheet.MODE -> recordingCategoryQuickControl(
                sheet, status, body, host.camera?.family.orEmpty(), labels, host.camera)?.let(::captured)
        }
    }

    public fun apply(sheet: LiveSheet, value: String, status: CameraStatus): Unit {
        host.nativeCaptureQuick(sheet, status)?.let { native ->
            if (native.enabled && value in native.options && value != native.selection) host.commitNativeCaptureQuick(sheet, value)
            return
        }
        val current = quick(sheet, status) ?: return
        if (!current.enabled || value !in current.options || value == current.selection) return
        fun commit(setting: CaptureSetting): Unit = host.commit(setting, host.captureField(sheet, status.expoMode), status)
        val preferences = host.capturePreferences
        when (sheet) {
            LiveSheet.ISO -> {
                val body = host.camera?.name.orEmpty()
                val floor = host.camera?.captureProfile?.isoAutoRangeFloor
                when (val command = IsoSheetLogic.applyDrum(value, status,
                    IsoSheetLogic.reseat(status, body, floor, readSessionState().controlCapabilities.nativeISO.ceiling == true).selectedMode, body, floor,
                    readSessionState().controlCapabilities.nativeISO.ceiling == true)) {
                    is IsoSheetLogic.Command.SetIndex -> commit(CaptureSetting.IsoIndex(command.index))
                    is IsoSheetLogic.Command.SetLimit -> commit(CaptureSetting.IsoLimitRaw(command.raw))
                    null -> Unit
                }
            }
            LiveSheet.SHUTTER -> when (val command = CaptureLists.applyShutterDrum(value,
                CaptureLists.isEvSheet(sheet, status.expoMode), preferences.shutterUsesAngle &&
                    status.expoMode != CameraCommands.EXPO_AUTO && !CameraCommands.isPhotoMode(status.shootingMode),
                preferences.facePriorityExposure, status)) {
                is CaptureLists.ShutterDrumCommand.SetEv -> commit(CaptureSetting.Ev(command.thirds))
                is CaptureLists.ShutterDrumCommand.SetShutter -> commit(CaptureSetting.ShutterDenom(command.denom))
                is CaptureLists.ShutterDrumCommand.SetAngle -> commit(CaptureSetting.ShutterAngle(command.degrees))
                CaptureLists.ShutterDrumCommand.Ignored -> Unit
            }
            LiveSheet.WB -> when {
                value == CaptureLists.AWB_LOCK -> commit(CaptureSetting.AutoWhiteBalanceLock)
                status.wbMode == CameraCommands.WB_CUSTOM && readSessionState().awbLockKelvin == null ->
                    CaptureLists.wbCustomFromKelvinLabel(value, status)?.let { commit(CaptureSetting.WhiteBalance(it.first, it.second)) }
                CaptureLists.wbSendsAuto(value) -> commit(CaptureSetting.WhiteBalanceAuto)
                else -> CaptureLists.wbCustomFromStatus(status).let { commit(CaptureSetting.WhiteBalance(it.first, it.second)) }
            }
            LiveSheet.FOCUS -> commit(CaptureSetting.Focus(value))
            LiveSheet.APERTURE -> CaptureLists.apertureFromLabel(value)?.let { commit(CaptureSetting.Aperture(it)) }
            LiveSheet.EXPO -> CaptureLists.expoModeFromLabel(value)?.let { commit(CaptureSetting.ExpoMode(it)) }
            LiveSheet.AUDIO -> {
                val service = host.audioService ?: return
                val field = service.fields.firstOrNull() ?: return
                if (field.isEditable) field.choices.firstOrNull { it.label == value }?.let { service.commit(it) }
            }
            LiveSheet.FORMAT -> {
                if (CameraCommands.isPhotoMode(status.shootingMode)) return
                val formatStatus = CaptureLists.withEffectiveVideoFormats(status, host.camera)
                val resolution = VideoResolution.fromRaw(formatStatus.resolutionCode) ?: return
                val aspect = resolution.aspect
                val tab = CaptureLists.formatResolutions(formatStatus, aspect).indexOf(resolution).coerceAtLeast(0)
                CaptureLists.nextVideoFormat(formatStatus, tab, value, fromDrum = true, aspect)?.let { commit(CaptureSetting.Format(it)) }
            }
            LiveSheet.COLOR -> CaptureLists.applyColorDrum(value, host.camera?.family.orEmpty(), status,
                preferences.nativeIsoHop, host.camera?.name.orEmpty(), host.labelProfile)
                ?.let { commit(CaptureSetting.ColorMode(it.colorMode)) }
            LiveSheet.MODE -> if (!status.isRecording) commit(CaptureSetting.ShootingMode(value))
        }
    }

    public fun release(sheet: LiveSheet, expected: MonitorQuickControl, value: String,
        lifetime: CaptureQuickLifetime, enabled: Boolean): Unit {
        val status = readStatus()
        val current = quick(sheet, status, lifetime)
        commitCaptureQuickControl(expected, current, value, enabled && lifetime.active && ready() && !busy()) {
            val field = (expected.identity as? Source)?.field
            if (field != null) {
                val editor = field.editor ?: return@commitCaptureQuickControl
                if (!control.isCurrent(editor)) return@commitCaptureQuickControl
                val choice = field.choices.firstOrNull { it.label == value && (sheet != LiveSheet.FOCUS ||
                    it.value == captureFocusValue(value, FocusTrackMode.fromRaw(status.focusTrack))) }
                if (choice != null) { control.commit(choice, field); return@commitCaptureQuickControl }
                if (sheet != LiveSheet.FOCUS) return@commitCaptureQuickControl
            }
            apply(sheet, value, status)
        }
    }

    private data class Source(val owner: MonitorOperatorCaptureSource, val session: CameraSessionID?,
        val epoch: ControlEpoch?, val capabilities: CapabilityRevision?, val presentationRevision: Long, val lifetime: CaptureQuickLifetime?,
        val revision: Long, val field: MonitorCaptureField?)
}

/** A held pointer cannot survive activity, mount, or native connection-phase retirement. */
@Composable
public fun rememberMonitorCaptureLifetime(source: MonitorOperatorCaptureSource): CaptureQuickLifetime {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifetime = remember(source, lifecycle) { CaptureQuickLifetime() }
    DisposableEffect(lifetime, lifecycle) {
        val observer = LifecycleEventObserver { _, _ -> lifetime.update(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
        lifecycle.addObserver(observer)
        lifetime.update(lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED))
        onDispose { lifecycle.removeObserver(observer); lifetime.update(false); lifetime.invalidate() }
    }
    LaunchedEffect(source, lifetime) { source.phaseEvents.collect { lifetime.invalidate() } }
    return lifetime
}

/** AF-C retains the native strategy reset until the camera reports the default track. */
public fun captureFocusValue(label: String, track: FocusTrackMode?): SettingValue? = when {
    label == "AF-S" -> SettingValue.FocusMode(FocusMode.SINGLE)
    label == "AF-C" && track == FocusTrackMode.DEFAULT -> SettingValue.FocusMode(FocusMode.CONTINUOUS)
    else -> null
}
