package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import com.opencapture.monitorui.MonitorExposureReadout
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorQuickControl
import com.opencapture.opencine.appkit.MonitorOperatorCaptureInputs
import com.opencapture.opencine.appkit.MonitorOperatorNativeCaptureQuick
import com.opencapture.opencine.vocabulary.ApertureStrategy
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.EvComp

public typealias MonitorOperatorLiveReadout<K, S> = com.opencapture.opencine.appkit.MonitorOperatorLiveReadout<K, S>
public typealias MonitorOperatorCameraPanel<K> = com.opencapture.opencine.appkit.MonitorOperatorCameraPanel<K>
public typealias MonitorOperatorCameraPanelChrome = com.opencapture.opencine.appkit.MonitorOperatorCameraPanelChrome

/** Retain the original source-owned quick control, including its phase lifetime and Core editor. */
public data class MonitorOperatorLegacyCaptureIdentity(public val sheet: LiveSheet, public val quick: MonitorQuickControl)

/** Existing native capture projection supplies values and typed actions, with no strip or drawer assembly. */
@Composable public fun <S> captureSheetHostInputs(source: MonitorOperatorCaptureSource, status: CameraStatus,
    active: LiveSheet?, onSheet: (LiveSheet?) -> Unit,
    section: S? = null, columns: Int? = null, metering: MonitorOperatorMeteringTile? = null,
    quickEnabled: Boolean = true,
    quickActiveChanged: (Boolean) -> Unit = {},
): MonitorOperatorCaptureInputs<String, S, MonitorOperatorLegacyCaptureIdentity> {
    val controlState by source.control.state.collectAsState()
    val native = source.host.captureSessionState(status)
    val controls = native.controlCapabilities
    val preferences = source.host.capturePreferences
    val lifetime = rememberMonitorCaptureLifetime(source)
    // One rule for the tile and its panel: the common program, else the native report.
    val auto = controlState.snapshot?.exposureProgram?.value == com.opencapture.opencine.core.CameraExposureProgram.AUTOMATIC ||
        status.expoMode == CameraCommands.EXPO_AUTO
    val expoMode = if (auto) CameraCommands.EXPO_AUTO else status.expoMode
    val shutter = captureShutterReadout(status, preferences.shutterUsesAngle, preferences.shutterAngleDegrees)
    val readouts = buildList<MonitorOperatorLiveReadout<String, S>> {
        fun append(sheet: LiveSheet, title: String, value: String, annotation: String? = null,
            icon: MonitorIcon? = null, badge: MonitorIcon? = null) {
            add(MonitorOperatorLiveReadout(sheet.name, title, value, section, icon = icon,
                badgeIcon = badge, annotation = annotation, quickEnabled = quickEnabled))
        }
        append(LiveSheet.ISO, "ISO", source.readout(LiveSheet.ISO, status, CaptureLists.isoChipValue(status)))
        append(LiveSheet.SHUTTER, if (auto) MonitorExposureReadout.autoEvCaption(status.shutterDenom) else "SHUTTER",
            source.readout(LiveSheet.SHUTTER, status, if (auto) EvComp.fromRaw(status.evComp)?.label ?: "--" else shutter),
            if (auto && preferences.facePriorityExposure) CaptureLists.FACE_PRIORITY_TITLE else null,
            badge = if (auto && preferences.facePriorityExposure) MonitorIcon.SCAN else null)
        append(LiveSheet.EXPO, "EXPOSURE", if (native.aeLocked) CaptureLists.AE_LOCK
            else controlState.snapshot?.exposureProgram?.value?.let(com.opencapture.opencine.appkit.MonitorCapturePresentation::exposureProgram) ?: "--")
        metering?.let { tile -> add(MonitorOperatorLiveReadout("METER", "METER", tile.label,
            section, action = { if (quickEnabled && lifetime.active) tile.perform() }, quickEnabled = false,
            actionIsCommand = true)) }
        append(LiveSheet.WB, "WB", source.readout(LiveSheet.WB, status, CaptureLists.wbChipValue(status, native.awbLockKelvin != null)),
            icon = if (CaptureLists.wbIsAuto(status) && native.awbLockKelvin == null) MonitorIcon.APERTURE else null)
        if (controls.focus.isOffered) append(LiveSheet.FOCUS, "FOCUS", source.readout(LiveSheet.FOCUS, status, status.focusLabel))
        if (controls.iris.isOffered) append(LiveSheet.APERTURE, "APERTURE", source.readout(LiveSheet.APERTURE, status, ApertureStrategy.tileValue(status)))
        if (controls.audio.isOffered && CaptureShutterPolicy.showsAudioControls(status.shootingMode)) append(LiveSheet.AUDIO, "AUDIO", status.audioLabel)
    }
    val panel = active?.let { sheet ->
        MonitorOperatorCameraPanel(sheet.name, sheet.isTopAnchored, chrome = MonitorOperatorCameraPanelChrome.CONTENT,
            title = CaptureLists.headerTitle(sheet, expoMode, status.shootingMode),
            subtitle = CaptureLists.headerSubtitle(sheet, expoMode,
                initialSelectedMode(sheet, status, native, preferences, CaptureLists.isEvSheet(sheet, expoMode)),
                preferences.facePriorityExposure, status.shootingMode).let {
                if (sheet == LiveSheet.SHUTTER && !auto) source.shutterPanelSubtitle(it, status) else it
            })
    }
    return MonitorOperatorCaptureInputs(readouts, panel, columns = columns, open = { id ->
        if (lifetime.active) {
            val sheet = LiveSheet.valueOf(id)
            val target = CaptureShutterPolicy.opening(sheet, status.shootingMode)
            onSheet(if (active == target) null else target)
        }
    }, dismiss = { onSheet(null) }, isTop = { id -> LiveSheet.entries.firstOrNull { it.name == id }?.isTopAnchored == true },
        nativeQuick = { id -> LiveSheet.entries.firstOrNull { it.name == id }?.let { sheet ->
            source.quick(sheet, status, lifetime)?.let { MonitorOperatorNativeCaptureQuick(MonitorOperatorLegacyCaptureIdentity(sheet, it), it) }
        } }, nativeCurrent = { id, identity -> lifetime.active && identity.sheet.name == id &&
            identity.quick == source.quick(identity.sheet, status, lifetime) }, nativeCommit = { id, identity, value ->
            if (identity.sheet.name == id) source.release(identity.sheet, identity.quick, value, lifetime, active == null)
        }, commitAdmission = { lifetime.active && active == null }, quickActiveChanged = quickActiveChanged,
        retireNative = source::retirePresentation)
}
