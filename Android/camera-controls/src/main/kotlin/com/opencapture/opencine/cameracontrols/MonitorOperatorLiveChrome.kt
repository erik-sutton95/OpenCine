package com.opencapture.opencine.cameracontrols

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import com.opencapture.monitorui.MonitorExposureReadout
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorValue
import com.opencapture.monitorui.MonitorZoomTapStops
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.ShellModel
import com.opencapture.opencine.core.MonitorLayoutCapabilities
import com.opencapture.opencine.vocabulary.ApertureStrategy
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraStatus
import com.opencapture.opencine.vocabulary.CaptureShutterPolicy
import com.opencapture.opencine.vocabulary.EvComp

/** Reported/native zoom facts. Tap choices and geometry are owned by the common chrome. */
public class MonitorOperatorZoomPresentation(
    public val factor: Double, public val dialFactor: Double, public val pinching: Boolean,
    public val dimmed: Boolean, public val maximum: Double, public val opticalStops: List<Double>,
    public val tapStops: MonitorZoomTapStops, public val cycleFrom: () -> Double,
    public val commitCycle: (Double) -> Unit, public val drag: (Double) -> Unit, public val endDrag: () -> Unit,
)

/** The platform adapter owns SDK movement; closing a panel never sends a motion command. */
public class MonitorOperatorStickActions(public val move: (Float, Float) -> Unit,
    public val release: () -> Unit, public val recenter: () -> Unit, public val flip: () -> Unit)

/** An optional observed metering choice. Its native setter remains in the integration adapter. */
public class MonitorOperatorMeteringTile(public val face: Boolean, public val toggle: () -> Unit)

/** Existing coherent hosts and stored preferences, with native zoom/stick facts as small adapters, and the
 * camera-vocabulary report and capabilities this composition observed. */
public class MonitorOperatorLiveChromeSource<Host>(
    public val host: Host, public val shell: ShellModel, public val session: MonitorOperatorSessionModel,
    public val capture: MonitorOperatorCaptureSource, public val preferences: OperatorPreferenceStore,
    public val portraitAspect: PortraitFeedAspect, public val setPortraitAspect: (PortraitFeedAspect) -> Unit,
    public val zoom: MonitorOperatorZoomPresentation?, public val stick: MonitorOperatorStickActions,
    public val returnToStage: (() -> Unit)? = null,
    public val status: CameraStatus, public val capabilities: MonitorLayoutCapabilities,
) where Host : CaptureSheetHost, Host : GimbalChromeHost

/** All capture values use the same held editor and full typed sheet, including observed optional metering. */
@Composable
public fun MonitorOperatorCaptureStrip(source: MonitorOperatorCaptureSource, status: CameraStatus,
    active: LiveSheet?, enabled: Boolean, portrait: Boolean, capabilities: MonitorLayoutCapabilities,
    modifier: Modifier = Modifier, metering: MonitorOperatorMeteringTile? = null,
    onOpen: (LiveSheet) -> Unit, onTileFrame: (LiveSheet, MonitorRect) -> Unit = { _, _ -> },
    onQuickActiveChange: (Boolean) -> Unit = {}, quickBottomClearanceDp: Float = 0f): Unit {
    source.control.state.collectAsState().value
    val native = source.host.captureSessionState(status)
    val preferences = source.host.capturePreferences
    val lifetime = rememberMonitorCaptureLifetime(source)
    val auto = status.expoMode == CameraCommands.EXPO_AUTO
    val shutter = captureShutterReadout(status, preferences.shutterUsesAngle, preferences.shutterAngleDegrees)
    fun value(sheet: LiveSheet, title: String, readout: String, annotation: String? = null,
        icon: MonitorIcon? = null, badge: MonitorIcon? = null): MonitorValue =
        MonitorValue(sheet.name, title, readout, active == sheet, annotation, icon, badge)
    val values = buildList {
        add(value(LiveSheet.ISO, "ISO", source.readout(LiveSheet.ISO, status, CaptureLists.isoChipValue(status))))
        add(value(LiveSheet.SHUTTER, if (auto) MonitorExposureReadout.autoEvCaption(status.shutterDenom) else "SHUTTER",
            source.readout(LiveSheet.SHUTTER, status, if (auto) EvComp.fromRaw(status.evComp)?.label ?: "\u2014" else shutter),
            if (auto && preferences.facePriorityExposure) CaptureLists.FACE_PRIORITY_TITLE else null,
            badge = if (auto && preferences.facePriorityExposure) MonitorIcon.SCAN else null))
        add(value(LiveSheet.EXPO, "EXPOSURE", if (native.aeLocked) CaptureLists.AE_LOCK
            else if (status.expoMode == CameraCommands.EXPO_MANUAL) "M" else if (auto) "A" else "\u2014"))
        metering?.let { add(MonitorValue(METER, "METER", if (it.face) "Face" else "Matrix")) }
        add(value(LiveSheet.WB, "WB", source.readout(LiveSheet.WB, status, CaptureLists.wbChipValue(status, native.awbLockKelvin != null)),
            icon = if (CaptureLists.wbIsAuto(status) && native.awbLockKelvin == null) MonitorIcon.APERTURE else null))
        if (capabilities.focus) add(value(LiveSheet.FOCUS, "FOCUS", status.focusLabel))
        if (capabilities.iris) add(value(LiveSheet.APERTURE, "APERTURE", ApertureStrategy.tileValue(status)))
        if (capabilities.audio && CaptureShutterPolicy.showsAudioControls(status.shootingMode))
            add(value(LiveSheet.AUDIO, "AUDIO", status.audioLabel))
    }
    com.opencapture.monitorui.MonitorCameraValues(values, enabled && lifetime.active, portrait, modifier,
        itemModifier = { id -> Modifier.reportChromeFrame { if (id != METER) onTileFrame(LiveSheet.valueOf(id), it) } },
        quickControl = { id -> if (id == METER) null else source.quick(LiveSheet.valueOf(id), status, lifetime) },
        onQuickCommit = { id, captured, selected -> source.release(LiveSheet.valueOf(id), captured, selected, lifetime, enabled && active == null) },
        quickPreview = { id, preview, maximum -> LiveControlSheet(LiveSheet.valueOf(id), source.host, status,
            locked = false, onDismiss = {}, maxHeightDp = maximum, preview = preview, portrait = portrait) },
        onQuickActiveChange = onQuickActiveChange, quickBottomClearanceDp = quickBottomClearanceDp,
        onOpen = { if (it == METER) metering?.toggle?.invoke() else onOpen(LiveSheet.valueOf(it)) })
}

private const val METER: String = "METER"
