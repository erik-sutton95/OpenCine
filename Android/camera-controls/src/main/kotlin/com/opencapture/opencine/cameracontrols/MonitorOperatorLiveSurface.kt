package com.opencapture.opencine.cameracontrols

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorToolUsageState
import com.opencapture.monitorui.PortraitZones
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.monitorui.portraitAssistToolbar
import com.opencapture.opencine.appkit.ChromeEditHost
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.appkit.MonitorDisplayChrome
import com.opencapture.opencine.appkit.MonitorDisplayMode
import com.opencapture.opencine.appkit.MonitorDisplaySection
import com.opencapture.opencine.appkit.MonitorInteractionTransition
import com.opencapture.opencine.appkit.MonitorOperatorCaptureInputs
import com.opencapture.opencine.appkit.MonitorOperatorCaptureState
import com.opencapture.opencine.appkit.MonitorOperatorSessionModel
import com.opencapture.opencine.appkit.rememberPhoneBatteryReadout
import com.opencapture.opencine.core.LocalVPNFilter
import com.opencapture.opencine.media.MonitorTransfer
import com.opencapture.opencine.media.ScopeAssistBundle
import com.opencapture.opencine.motion.LevelReading
import com.opencapture.opencine.vocabulary.ControlHud
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow

/** Geometry is a value; decoder/native surface identity is never owned by this module. */
public class MonitorOperatorLiveLayout(public val layout: LiveMonitorLayout, public val zones: PortraitZones?,
    public val pictureContent: MonitorRect, public val scopePlacement: MonitorRect, public val pictureAspect: Float)

/** Portable scope publications plus one bounded native inspector picture and a typed look picker. */
public class MonitorOperatorAssistSource(public val host: AssistHost,
    public val scopes: Flow<ScopeAssistBundle>?, public val scopeStackMoved: () -> Unit,
    public val lookPicker: AssistLutPicker?, public val preview: (@Composable (MonitorAssistTool) -> Unit)? = null,
    public val panelPlacement: MonitorAssistPanelPlacement? = null,
    public val lookMenu: (@Composable () -> Unit)? = null,
    public val paradeIntensityScale: Double = 1.0)

/** The picture the source delivers: its aspect, whether the first frame is still awaited, whether the
 * camera shows it vertically or mirrored, and whether the link is recovering. */
public data class MonitorOperatorLivePicture(public val aspect: Float, public val waiting: Boolean,
    public val vertical: Boolean, public val flipped: Boolean, public val recovering: Boolean)

/** How this source records. Photo mode releases through the native shutter slot. */
public class MonitorOperatorRecordSource(public val photo: Boolean, public val confirm: Boolean,
    public val busy: Boolean, public val openMode: (() -> Unit)?)

/**
 * Everything a source knows about its live monitor, read at the call site. Unknown values stay absent:
 * a source without an exposure meter or a level passes null.
 */
public class MonitorOperatorLiveSource<K, N>(
    /** Re-read before every release, so a callback never acts for a replaced source. */
    public val identity: () -> MonitorOperatorLiveIdentity,
    /** The sections something can fill now. Chrome the operator switched on still hides when nothing
     * feeds it: an empty readout looks like an attached, silent camera. */
    public val available: Set<MonitorDisplaySection>,
    public val picture: MonitorOperatorLivePicture,
    public val status: MonitorOperatorLiveStatus<K, MonitorDisplaySection>,
    public val cameraBattery: MonitorOperatorPowerReading?,
    public val capture: MonitorOperatorCaptureInputs<K, MonitorDisplaySection, N>,
    public val record: MonitorOperatorRecordSource,
    /** The camera's metered EV in raw thirds; null when the source has no meter, a null reading while unknown. */
    public val exposure: (() -> Int?)?,
    public val level: LevelReading?,
    public val levelViewFlip: Boolean,
    public val audio: Pair<AudioMeterReading, AudioMeterReading>?,
    /** Control surrendered to another operator: presentation stays, commands are refused. */
    public val readOnly: Boolean,
    /** A multicam member lent to this monitor: Media stays with the stage. */
    public val borrowed: Boolean,
    public val returnToStage: (() -> Unit)?,
    public val coverOpen: Boolean,
    /** The one note sink. Refusals, interruptions and hints appear in one placement. */
    public val note: String?,
    public val clearNote: (String) -> Unit,
    /** The platform's tunnel probe for the waiting picture's hint; it lives below this module. */
    public val vpnActive: () -> Boolean,
    public val settings: () -> Unit,
    public val media: () -> Unit,
)

/** The assist palette the source offers. [scopes] null renders the palette without scopes or inspectors. */
public class MonitorOperatorLiveAssists(
    public val scopes: MonitorOperatorAssistSource?, public val palette: List<MonitorOperatorPaletteItem>,
    public val rendered: Set<MonitorAssistTool>, public val transfer: MonitorTransfer?,
    public val signalOptions: MonitorOperatorSignalOptions, public val usage: MonitorToolUsageState,
    public val setUsage: (MonitorToolUsageState) -> Unit, public val usageSeed: Map<String, Int>,
)

/**
 * The one live monitor every app composes. The source supplies what it knows, the session supplies the
 * operator's display intent (mode, chrome, editor, lock, arming), and every policy lives here once:
 * record confirmation, connect-tap arming, borrowed media, the note banner, phone and camera power,
 * the waiting picture, the instruments and the command mode. Swift twin: `MonitorOperatorLiveSurface`.
 */
@Composable
public fun <K, N> MonitorOperatorLiveSurface(control: MonitorControlModel, session: MonitorOperatorSessionModel,
    geometry: MonitorOperatorLiveLayout, source: MonitorOperatorLiveSource<K, N>, assists: MonitorOperatorLiveAssists,
    views: MonitorOperatorBodyViews, modifier: Modifier = Modifier,
    transitionChanged: (MonitorInteractionTransition) -> Unit = {},
    picture: @Composable BoxScope.() -> Unit,
    cameraPanel: @Composable (K, MonitorRect, Boolean, MonitorOperatorCaptureState<K, N>) -> Unit,
    photoRelease: (@Composable (Boolean, Modifier) -> Unit)?): Unit {
    val layout = geometry.layout
    val zones = geometry.zones
    val assist = session.assist
    val mode = session.mode
    val command = mode == MonitorDisplayMode.COMMAND
    val common by control.state.collectAsState()
    val identity = source.identity()
    val host = remember(session) { operatorChromeHost(session) }
    val mounted = MonitorDisplaySection.entries.filter { it in source.available && session.mounts(it) }.toSet()
    val phone = rememberPhoneBatteryReadout()
    LaunchedEffect(source.note, common.snapshot?.session, common.snapshot?.epoch) {
        val note = source.note ?: return@LaunchedEffect
        val camera = common.snapshot?.let { it.session to it.epoch }
        delay((ControlHud.TOAST_HOLD_SECONDS * 1000).toLong())
        if (control.state.value.snapshot?.let { it.session to it.epoch } == camera) source.clearNote(note)
    }
    // The dashboard replaces the picture: no popup survives entering it (the composition drops the inspector).
    LaunchedEffect(command) { if (command) source.capture.dismiss() }
    var paletteBounds by remember(layout.viewportWidth, layout.viewportHeight) { mutableStateOf<MonitorRect?>(null) }
    val desqueezed = assist.isVisible(MonitorAssistTool.DESQ)
    val meterFeed = if (desqueezed) geometry.pictureContent else layout.onFeed
    val paletteBoundsForMeter = if (MonitorDisplaySection.TOOL_BAR !in mounted || source.coverOpen ||
        assist.configureTool != null) null else paletteBounds ?: if (zones != null)
        portraitAssistToolbar(zones.assistToolbar.minY, minOf(layout.viewportWidth, layout.viewportHeight) >= 600f) else layout.assist
    val feed = if (desqueezed) geometry.pictureContent else layout.onFeed.fittedContent(source.picture.aspect)
    val framing = if (desqueezed) geometry.pictureContent.fittedContent(assist.presentedAspect(source.picture.aspect)) else null
    val bodyViews = MonitorOperatorBodyViews(focusDrive = views.focusDrive, dashboard = views.dashboard,
        focusMarks = views.focusMarks, feedGestures = views.feedGestures, motion = views.motion, focusControls = { enabled ->
            source.exposure?.let { read ->
                if (assist.evMeter && mode == MonitorDisplayMode.LIVE) {
                    val raw = read()
                    MonitorOperatorExposureMeter(raw ?: 0, raw != null && !source.picture.recovering, meterFeed, mode,
                        Modifier.zIndex(1f), paletteBoundsForMeter)
                }
            }
            if (source.level != null && assist.isVisible(MonitorAssistTool.LEVEL))
                MonitorOperatorLevelOverlay(source.level, source.levelViewFlip, meterFeed,
                    MonitorRect(0f, 0f, layout.viewportWidth, layout.viewportHeight), zones != null, Modifier.zIndex(1f))
            views.focusControls?.invoke(this, enabled)
        }, waitingPicture = {
            if (source.picture.waiting) OperatorWaitingPicture(layout.onFeed, control, source.vpnActive)
            views.waitingPicture?.invoke()
        }, feedback = {
            OperatorToast(source.note, layout, MonitorDisplaySection.STATUS_BAR in mounted)
            views.feedback?.invoke(this)
        })
    val index = session.modes.indexOf(mode).takeIf { it >= 0 }
    val viewport = MonitorRect(layout.safeLeading, layout.safeTop,
        maxOf(0f, layout.viewportWidth - layout.safeLeading - layout.safeTrailing),
        maxOf(0f, layout.viewportHeight - layout.safeTop - layout.safeBottom))
    MonitorOperatorLiveComposition(control, identity, { it == source.identity() }, checkNotNull(layout.field), viewport,
        MonitorOperatorLiveSections(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.BATTERIES,
            MonitorDisplaySection.CAMERA_VALUES, MonitorDisplaySection.TOOL_BAR, MonitorDisplaySection.LOCK_BUTTON,
            MonitorDisplaySection.RAIL_SETTINGS, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_RECORD, null),
        mounted, host, session.editingMode, session.locked, { session.locked = it }, source.coverOpen,
        mode == MonitorDisplayMode.CLEAN, command, source.readOnly, source.picture.recovering, source.status,
        listOfNotNull(MonitorOperatorPowerReading(false, phone.percent, phone.externalPower), source.cameraBattery),
        source.capture, {}, source.settings, source.media, { session.cycle() }, index, session.modes.size,
        source.record.photo, source.record.confirm, !source.record.busy, assist = assist, assists = assists.scopes,
        palette = assists.palette, usage = assists.usage, setUsage = assists.setUsage, usageSeed = assists.usageSeed,
        renderedTools = assists.rendered, fittedScopes = emptyList(), scopeZone = null,
        signalOptions = assists.signalOptions, audioChannels = source.audio, cameraViews = bodyViews,
        modifier = modifier, displayTitle = index?.let { "DISP ${it + 1} ${mode.title.lowercase()}" },
        openMode = source.record.openMode,
        recordConfirmationPolicy = MonitorControlModel.RecordConfirmationPolicy.UNCHANGED_RECORDING,
        interactionEnabled = session.interactive, borrowed = source.borrowed, returnToStage = source.returnToStage,
        safeLeading = layout.safeLeading, safeTrailing = layout.safeTrailing, safeTop = layout.safeTop,
        safeBottom = layout.safeBottom, scopeFeed = feed, framingFrame = framing,
        scopePlacement = geometry.scopePlacement, scopeFloating = true, scopeTransfer = assists.transfer,
        paletteFrameChanged = { paletteBounds = it }, transitionChanged = transitionChanged,
        picture = { Box(Modifier.matchParentSize().then(if (command) Modifier.alpha(0f) else Modifier)) { picture() } },
        cameraPanel = cameraPanel, photoRelease = photoRelease)
}

@Composable
private fun OperatorWaitingPicture(frame: MonitorRect, control: MonitorControlModel, vpnActive: () -> Boolean): Unit {
    var hint by remember { mutableStateOf(false) }
    val state by control.state.collectAsState()
    val snapshot = state.snapshot
    LaunchedEffect(snapshot?.session, snapshot?.epoch) {
        hint = false
        delay(LocalVPNFilter.LIVE_HINT_DELAY_MS)
        hint = LocalVPNFilter.shouldHintOnLiveWait(vpnActive(), false, LocalVPNFilter.LIVE_HINT_DELAY_SECONDS)
    }
    Box(Modifier.frame(frame).background(Color.Black), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(color = LiveDesign.text.copy(alpha = .72f))
            Text("WAITING FOR LIVE VIEW", color = LiveDesign.text.copy(alpha = .72f), style = LiveType.mono(15f, FontWeight.SemiBold))
            if (hint) Text(LocalVPNFilter.LIVE_HINT, color = LiveDesign.muted, style = LiveType.ui(12f),
                textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 28.dp))
        }
    }
}

/** The one note placement, under the status deck at the top capsule. */
@Composable
private fun BoxScope.OperatorToast(note: String?, layout: LiveMonitorLayout, statusMounted: Boolean): Unit {
    if (note.isNullOrEmpty()) return
    val y = ControlHud.toastCenterY(layout.onFeed.minY.toDouble(), if (statusMounted && layout.topDeck.height > 1f)
        layout.topDeck.maxY.toDouble() else null).toFloat()
    val parked by animateFloatAsState(y, tween(180), label = "toastY")
    var height by remember { mutableIntStateOf(0) }
    val density = LocalDensity.current
    Text(note, color = LiveDesign.text.copy(alpha = .92f), style = LiveType.ui(12f, FontWeight.SemiBold),
        modifier = Modifier.align(Alignment.TopCenter).onSizeChanged { height = it.height }
            .offset { IntOffset(0, with(density) { parked.dp.roundToPx() } - height / 2) }
            .clip(RoundedCornerShape(50)).monitorMaterial(MonitorMaterial.Compact, RoundedCornerShape(50))
            .padding(horizontal = 12.dp, vertical = 6.dp))
}

private fun Modifier.frame(rect: MonitorRect): Modifier = offset(rect.x.dp, rect.y.dp).size(rect.width.dp, rect.height.dp)

internal fun operatorChromeHost(session: MonitorOperatorSessionModel): ChromeEditHost<MonitorDisplaySection, MonitorDisplayMode> =
    object : ChromeEditHost<MonitorDisplaySection, MonitorDisplayMode> {
        override val chromeEditSections = MonitorDisplaySection.entries
        override fun chromeSectionTitle(section: MonitorDisplaySection) = section.title
        override fun chromeSectionID(section: MonitorDisplaySection) = section.key
        override fun chromeModeTitle(mode: MonitorDisplayMode) = mode.title
        override fun isChromeConfigurable(section: MonitorDisplaySection, mode: MonitorDisplayMode) =
            MonitorDisplayChrome.isConfigurable(section, mode)
        override fun isChromeVisible(section: MonitorDisplaySection, mode: MonitorDisplayMode) = session.chrome(mode).isVisible(section)
        override fun toggleChrome(section: MonitorDisplaySection, mode: MonitorDisplayMode) = session.toggle(section, mode)
        override fun endChromeEditing() = session.finishEditing()
    }
