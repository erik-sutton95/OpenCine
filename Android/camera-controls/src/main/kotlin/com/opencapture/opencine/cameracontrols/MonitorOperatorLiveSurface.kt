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
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
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
import androidx.compose.ui.semantics.semantics
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
import com.opencapture.monitorui.portraitAspectToggle
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
 * camera shows it vertically or mirrored, and whether the link is recovering. A [notice] replaces the
 * waiting plate's words when the source has no picture to wait for (no camera, a reconnect, a network hop). */
public data class MonitorOperatorLivePicture(public val aspect: Float, public val waiting: Boolean,
    public val vertical: Boolean, public val flipped: Boolean, public val recovering: Boolean,
    public val notice: MonitorOperatorPictureNotice? = null,
    /**
     * An automatic reconnect is running (Swift `reconnecting`); follows [recovering] unless the
     * source's recovery can wait for the operator (taken over, paused, out of attempts).
     */
    public val reconnecting: Boolean = recovering) {
    /** The plate covers the picture well: the source's notice, else the waiting plate. */
    public val plate: MonitorOperatorPicturePlate? get() = when {
        notice != null -> MonitorOperatorPicturePlate.Notice(notice)
        waiting -> MonitorOperatorPicturePlate.Waiting
        else -> null
    }
}

/** What covers the picture well: the waiting plate, or the plate's look with the source's notice. */
public sealed interface MonitorOperatorPicturePlate {
    public data object Waiting : MonitorOperatorPicturePlate
    public data class Notice(public val notice: MonitorOperatorPictureNotice) : MonitorOperatorPicturePlate
}

/** The picture well's own words: a title, an optional detail, and whether work is under way (a spinner). */
public data class MonitorOperatorPictureNotice(public val title: String, public val detail: String? = null,
    public val progress: Boolean = false)

/** How this source records. Photo mode releases through the native shutter slot. [confirmingChanged]
 * reports the record confirmation opening and closing, for record paths outside the monitor (a watch, a
 * hardware shutter) that stand down while it is up. */
public class MonitorOperatorRecordSource(public val photo: Boolean, public val confirm: Boolean,
    public val busy: Boolean, public val openMode: (() -> Unit)?,
    public val confirmingChanged: (Boolean) -> Unit = {})

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
    /** The camera's metered exposure in stops; null when the source has no meter, a null reading while unknown. */
    public val exposure: (() -> Double?)?,
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
    /** The camera's own level meter with its caption, for a source that reports one apart from [audio]. */
    public val audioLevels: MonitorOperatorLiveAudio? = null,
)

/** The assist palette the source offers. [scopes] null renders the palette without scopes or inspectors.
 * [fitted] scopes stack under a portrait fit picture instead of floating over it. */
public class MonitorOperatorLiveAssists(
    public val scopes: MonitorOperatorAssistSource?, public val palette: List<MonitorOperatorPaletteItem>,
    public val rendered: Set<MonitorAssistTool>, public val transfer: MonitorTransfer?,
    public val signalOptions: MonitorOperatorSignalOptions, public val usage: MonitorToolUsageState,
    public val setUsage: (MonitorToolUsageState) -> Unit, public val usageSeed: Map<String, Int>,
    public val fitted: List<MonitorAssistTool> = emptyList(),
)

/**
 * The one live monitor every app composes. The source supplies what it knows, the session supplies the
 * operator's display intent (mode, chrome, editor, lock, arming), and every policy lives here once:
 * record confirmation, connect-tap arming, borrowed media, the note banner, phone and camera power,
 * the waiting picture, the instruments, the portrait fit/fill key and the command mode. A source that offers
 * no fit/fill choice now passes a null [portraitAspect]. Swift twin: `MonitorOperatorLiveSurface`.
 */
@Composable
public fun <K, N> MonitorOperatorLiveSurface(control: MonitorControlModel, session: MonitorOperatorSessionModel,
    geometry: MonitorOperatorLiveLayout, source: MonitorOperatorLiveSource<K, N>, assists: MonitorOperatorLiveAssists,
    views: MonitorOperatorBodyViews, modifier: Modifier = Modifier,
    portraitAspect: PortraitFeedAspect? = null, setPortraitAspect: (PortraitFeedAspect) -> Unit = {},
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
    val field = checkNotNull(layout.field)
    // Portrait fit stacks the fitted scopes between the picture and the camera values.
    val scopeZone = if (assists.fitted.isNotEmpty()) monitorOperatorFittedScopeZone(field) else null
    val aspect = portraitAspect?.takeIf { field.portrait && !source.picture.vertical && session.editingMode == null &&
        !desqueezed && !command }?.let { current ->
        val fills = current == PortraitFeedAspect.FILL
        MonitorOperatorAspectControl(zones?.let { portraitAspectToggle(layout.viewportWidth, it.assistToolbar.minY) }
            ?: field.aspectToggle, fills) { setPortraitAspect(if (fills) PortraitFeedAspect.FIT_16X9 else PortraitFeedAspect.FILL) }
    }
    val boxes = remember { mutableStateMapOf<MonitorDisplaySection, MonitorRect>() }
    val chromeEdit = MonitorOperatorChromeEdit(host, session.editingMode, boxes)
    val bodyViews = MonitorOperatorBodyViews(focusDrive = views.focusDrive, dashboard = views.dashboard,
        resetFocus = views.resetFocus, comparison = views.comparison,
        focusMarks = views.focusMarks, feedGestures = views.feedGestures, motion = views.motion, focusControls = { enabled ->
            source.exposure?.let { read ->
                if (assist.evMeter && mode == MonitorDisplayMode.LIVE) {
                    val stops = read()
                    MonitorOperatorExposureMeter(stops, stops != null && !source.picture.recovering, meterFeed, mode,
                        Modifier.zIndex(1f), paletteBoundsForMeter)
                }
            }
            if (source.level != null && assist.isVisible(MonitorAssistTool.LEVEL))
                MonitorOperatorLevelOverlay(source.level, source.levelViewFlip, meterFeed,
                    MonitorRect(0f, 0f, layout.viewportWidth, layout.viewportHeight), zones != null, Modifier.zIndex(1f))
            views.focusControls?.invoke(this, enabled)
        }, waitingPicture = {
            when (val plate = source.picture.plate) {
                is MonitorOperatorPicturePlate.Notice -> OperatorPictureNotice(layout.onFeed, plate.notice)
                MonitorOperatorPicturePlate.Waiting -> OperatorWaitingPicture(layout.onFeed, control, source.vpnActive)
                null -> Unit
            }
            views.waitingPicture?.invoke()
        }, feedback = {
            OperatorToast(source.note, layout, MonitorDisplaySection.STATUS_BAR in mounted)
            views.feedback?.invoke(this)
        })
    val index = session.modes.indexOf(mode).takeIf { it >= 0 }
    val viewport = MonitorRect(layout.safeLeading, layout.safeTop,
        maxOf(0f, layout.viewportWidth - layout.safeLeading - layout.safeTrailing),
        maxOf(0f, layout.viewportHeight - layout.safeTop - layout.safeBottom))
    MonitorOperatorLiveComposition(control, identity, { it == source.identity() }, field, viewport,
        MonitorOperatorLiveSections(MonitorDisplaySection.STATUS_BAR, MonitorDisplaySection.BATTERIES,
            MonitorDisplaySection.CAMERA_VALUES, MonitorDisplaySection.TOOL_BAR, MonitorDisplaySection.LOCK_BUTTON,
            MonitorDisplaySection.RAIL_SETTINGS, MonitorDisplaySection.RAIL_MEDIA, MonitorDisplaySection.RAIL_RECORD, null),
        mounted, host, session.editingMode, session.locked, { session.locked = it }, source.coverOpen,
        mode == MonitorDisplayMode.CLEAN, command, source.readOnly, source.picture.recovering, source.status,
        listOfNotNull(MonitorOperatorPowerReading(false, phone.percent, phone.externalPower), source.cameraBattery),
        source.capture, {}, source.settings, source.media, { session.cycle() }, index, session.modes.size,
        source.record.photo, source.record.confirm, !source.record.busy, onRecordConfirming = source.record.confirmingChanged,
        assist = assist, assists = assists.scopes,
        palette = assists.palette, usage = assists.usage, setUsage = assists.setUsage, usageSeed = assists.usageSeed,
        renderedTools = assists.rendered, fittedScopes = if (scopeZone != null) assists.fitted else emptyList(), scopeZone = scopeZone,
        signalOptions = assists.signalOptions, audioChannels = source.audio, aspect = aspect, focusResetFrame = layout.focusReset,
        cameraViews = bodyViews, chromeBoxes = boxes, audio = source.audioLevels,
        modifier = modifier, displayTitle = index?.let { "DISP ${it + 1} ${mode.title.lowercase()}" },
        openMode = source.record.openMode,
        interactionEnabled = session.interactive, borrowed = source.borrowed, returnToStage = source.returnToStage,
        safeLeading = layout.safeLeading, safeTrailing = layout.safeTrailing, safeTop = layout.safeTop,
        safeBottom = layout.safeBottom, scopeFeed = feed, framingFrame = framing,
        scopePlacement = geometry.scopePlacement, scopeFloating = scopeZone == null, scopeTransfer = assists.transfer,
        paletteFrameChanged = { paletteBounds = it }, transitionChanged = transitionChanged,
        picture = {
            CompositionLocalProvider(LocalMonitorOperatorChromeEdit provides chromeEdit) {
                Box(Modifier.matchParentSize().then(if (command) Modifier.alpha(0f) else Modifier)) { picture() }
            }
        },
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

/** The waiting plate's look with the source's own words. */
@Composable
private fun OperatorPictureNotice(frame: MonitorRect, notice: MonitorOperatorPictureNotice): Unit {
    Box(Modifier.frame(frame).background(Color.Black).semantics(mergeDescendants = true) {},
        contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(horizontal = 28.dp)) {
            if (notice.progress) CircularProgressIndicator(color = LiveDesign.text.copy(alpha = .72f))
            Text(notice.title, color = LiveDesign.text.copy(alpha = .72f), style = LiveType.mono(15f, FontWeight.SemiBold),
                textAlign = TextAlign.Center)
            notice.detail?.let { Text(it, color = LiveDesign.muted, style = LiveType.ui(12f), textAlign = TextAlign.Center) }
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

private val BADGE_ORDER: List<MonitorDisplaySection> =
    listOf(MonitorDisplaySection.LOCK_BUTTON, MonitorDisplaySection.BATTERIES,
        MonitorDisplaySection.CODEC) +
        MonitorDisplaySection.entries.filter {
            it != MonitorDisplaySection.LOCK_BUTTON && it != MonitorDisplaySection.BATTERIES &&
                it != MonitorDisplaySection.CODEC
        }

internal fun operatorChromeHost(session: MonitorOperatorSessionModel): ChromeEditHost<MonitorDisplaySection, MonitorDisplayMode> =
    object : ChromeEditHost<MonitorDisplaySection, MonitorDisplayMode> {
        // The lock and batteries take their corners first: on a phone with no top cutout the battery band sits on
        // the status row, and the status bar's eye would otherwise land on the batteries'. CODEC follows them
        // because its portrait detail box nests inside the status band; a nested box cannot stack outward, so
        // the enclosing status eye would otherwise take the only free corner and drop the codec eye.
        override val chromeEditSections = BADGE_ORDER
        override fun chromeSectionTitle(section: MonitorDisplaySection) = section.title
        override fun chromeSectionID(section: MonitorDisplaySection) = section.key
        override fun chromeModeTitle(mode: MonitorDisplayMode) = mode.title
        override fun isChromeConfigurable(section: MonitorDisplaySection, mode: MonitorDisplayMode) =
            MonitorDisplayChrome.isConfigurable(section, mode)
        override fun isChromeVisible(section: MonitorDisplaySection, mode: MonitorDisplayMode) = session.chrome(mode).isVisible(section)
        override fun toggleChrome(section: MonitorDisplaySection, mode: MonitorDisplayMode) = session.toggle(section, mode)
        override fun endChromeEditing() = session.finishEditing()
    }
