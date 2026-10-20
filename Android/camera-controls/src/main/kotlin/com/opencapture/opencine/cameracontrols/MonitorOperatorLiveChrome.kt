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
public class MonitorOperatorMeteringTile(
    /** Face priority (`true`) or matrix (`false`); `null` is unknown and has no toggle target. */
    public val face: Boolean?,
    private val isCurrent: () -> Boolean = { true },
    public val toggle: () -> Unit,
) {
    /** The strip value, with the strip placeholder while the mode is unknown. */
    public val label: String get() = face?.let { if (it) "Face" else "Matrix" } ?: "--"

    /** Acts only on a known mode, for the source and phase the tile was drawn for. */
    public fun perform() { if (face != null && isCurrent()) toggle() }
}

/** Existing coherent hosts and stored preferences, with native zoom/stick facts as small adapters, and the
 * camera-vocabulary report and capabilities this composition observed. */
public class MonitorOperatorLiveChromeSource<Host>(
    public val host: Host, public val shell: ShellModel, public val session: MonitorOperatorSessionModel,
    public val capture: MonitorOperatorCaptureSource, public val preferences: OperatorPreferenceStore,
    public val portraitAspect: PortraitFeedAspect, public val setPortraitAspect: (PortraitFeedAspect) -> Unit,
    public val zoom: MonitorOperatorZoomPresentation?, public val stick: MonitorOperatorStickActions,
    public val returnToStage: (() -> Unit)? = null,
    public val status: CameraStatus, public val capabilities: MonitorLayoutCapabilities,
    /** The operator's remote shutter choice; it records only where the app provides [LocalMonitorRemoteShutter]. */
    public val remoteShutterEnabled: Boolean = false,
) where Host : CaptureSheetHost, Host : GimbalChromeHost

/** All capture values use the same held editor and full typed sheet, including observed optional metering. */
@Composable
public fun MonitorOperatorCaptureStrip(source: MonitorOperatorCaptureSource, status: CameraStatus,
    active: LiveSheet?, enabled: Boolean, portrait: Boolean,
    modifier: Modifier = Modifier, metering: MonitorOperatorMeteringTile? = null,
    onOpen: (LiveSheet) -> Unit, onTileFrame: (LiveSheet, MonitorRect) -> Unit = { _, _ -> },
    onQuickActiveChange: (Boolean) -> Unit = {}, quickBottomClearanceDp: Float = 0f): Unit {
    val controlState by source.control.state.collectAsState()
    val native = source.host.captureSessionState(status)
    val controls = native.controlCapabilities
    val preferences = source.host.capturePreferences
    val lifetime = rememberMonitorCaptureLifetime(source)
    // One rule for the tile and its panel: the common program, else the native report.
    val auto = controlState.snapshot?.exposureProgram?.value == com.opencapture.opencine.core.CameraExposureProgram.AUTOMATIC ||
        status.expoMode == CameraCommands.EXPO_AUTO
    val shutter = captureShutterReadout(status, preferences.shutterUsesAngle, preferences.shutterAngleDegrees)
    fun value(sheet: LiveSheet, title: String, readout: String, annotation: String? = null,
        icon: MonitorIcon? = null, badge: MonitorIcon? = null): MonitorValue =
        MonitorValue(sheet.name, title, readout, active == sheet, annotation, icon, badge)
    val values = buildList {
        add(value(LiveSheet.ISO, "ISO", source.readout(LiveSheet.ISO, status, CaptureLists.isoChipValue(status))))
        add(value(LiveSheet.SHUTTER, if (auto) MonitorExposureReadout.autoEvCaption(status.shutterDenom) else "SHUTTER",
            source.readout(LiveSheet.SHUTTER, status, if (auto) EvComp.fromRaw(status.evComp)?.label ?: "--" else shutter),
            if (auto && preferences.facePriorityExposure) CaptureLists.FACE_PRIORITY_TITLE else null,
            badge = if (auto && preferences.facePriorityExposure) MonitorIcon.SCAN else null))
        add(value(LiveSheet.EXPO, "EXPOSURE", if (native.aeLocked) CaptureLists.AE_LOCK
            else controlState.snapshot?.exposureProgram?.value?.let(com.opencapture.opencine.appkit.MonitorCapturePresentation::exposureProgram) ?: "--"))
        metering?.let { add(MonitorValue(METER, "METER", it.label)) }
        add(value(LiveSheet.WB, "WB", source.readout(LiveSheet.WB, status, CaptureLists.wbChipValue(status, native.awbLockKelvin != null)),
            icon = if (CaptureLists.wbIsAuto(status) && native.awbLockKelvin == null) MonitorIcon.APERTURE else null))
        if (controls.focus.isOffered) add(value(LiveSheet.FOCUS, "FOCUS", source.readout(LiveSheet.FOCUS, status, status.focusLabel)))
        if (controls.iris.isOffered) add(value(LiveSheet.APERTURE, "APERTURE", source.readout(LiveSheet.APERTURE, status, ApertureStrategy.tileValue(status))))
        if (controls.audio.isOffered && CaptureShutterPolicy.showsAudioControls(status.shootingMode))
            add(value(LiveSheet.AUDIO, "AUDIO", status.audioLabel))
    }
    com.opencapture.monitorui.MonitorCameraValues(values, enabled && lifetime.active, portrait, modifier,
        itemModifier = { id -> Modifier.reportChromeFrame { if (id != METER) onTileFrame(LiveSheet.valueOf(id), it) } },
        quickControl = { id -> if (id == METER) null else source.quick(LiveSheet.valueOf(id), status, lifetime) },
        onQuickCommit = { id, captured, selected -> source.release(LiveSheet.valueOf(id), captured, selected, lifetime, enabled && active == null) },
        quickPreview = { id, preview, maximum -> LiveControlSheet(LiveSheet.valueOf(id), source.host, status,
            locked = false, onDismiss = {}, maxHeightDp = maximum, preview = preview, portrait = portrait,
            shutterAngleSettling = source.shutterAngleSettling) },
        onQuickActiveChange = onQuickActiveChange, quickBottomClearanceDp = quickBottomClearanceDp,
        onOpen = { if (it == METER) metering?.perform() else onOpen(LiveSheet.valueOf(it)) })
}

private const val METER: String = "METER"
