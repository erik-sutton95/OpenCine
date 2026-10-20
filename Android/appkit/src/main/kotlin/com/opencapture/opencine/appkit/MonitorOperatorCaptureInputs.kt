package com.opencapture.opencine.appkit

import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.*
import com.opencapture.opencine.core.CameraSessionID
import com.opencapture.opencine.core.ControlEpoch

/** Reported data remains distinct from captured command admission. */
public class MonitorOperatorLiveReadout<K, S>(
    public val id: K, public val title: String, public val value: String?, public val section: S? = null,
    public val field: MonitorCaptureField? = null, public val action: (() -> Unit)? = null,
    public val quickEnabled: Boolean = true, public val itemModifier: Modifier = Modifier,
    public val icon: MonitorIcon? = null, public val badgeIcon: MonitorIcon? = null,
    public val annotation: String? = null,
    public val actionIsCommand: Boolean = false,
    /** The complete spoken readout when [value] is compacted ("20282 shots remaining" for "20.2k"). */
    public val accessibilityLabel: String? = null,
    /** The camera owns or locks this value: the cell reads muted, as the source decides. */
    public val dimmed: Boolean = false,
    /** A hold on the cell while it has no quick adjust (for example a camera-side lock toggle). */
    public val holdAction: (() -> Unit)? = null,
)

public enum class MonitorOperatorCameraPanelChrome { DESCRIPTOR, CONTENT, SHARED_SHEET }

/** Native extensions provide controls only, inside the one common drawer. */
public class MonitorOperatorCameraPanel<K>(
    public val key: K, public val top: Boolean, public val preferredWidth: Float = 340f,
    public val maximumHeight: Float = 300f,
    public val chrome: MonitorOperatorCameraPanelChrome = MonitorOperatorCameraPanelChrome.DESCRIPTOR,
    public val title: String? = null, public val subtitle: String? = null,
    public val field: MonitorCaptureField? = null,
)

public data class MonitorCaptureSourceIdentity(
    public val camera: CameraSessionID?, public val epoch: ControlEpoch?, public val pictureOwner: Any?,
    public val monitor: Any? = null, public val picture: String? = null, public val phase: String? = null,
)

/** Native control bodies consume the same write gate as the common descriptor drum. */
public val LocalMonitorCaptureCommandEnabled: androidx.compose.runtime.ProvidableCompositionLocal<Boolean> = staticCompositionLocalOf { true }

public data class MonitorOperatorNativeCaptureQuick<N>(public val identity: N, public val control: MonitorQuickControl)

public data class MonitorOperatorCapturePreview<K, N>(public val key: K, public val preview: MonitorQuickPreview,
    public val field: MonitorCaptureField?, public val native: N?)

public data class MonitorOperatorCaptureHeaderValues<K>(public val key: K, public val title: String, public val subtitle: String)

public class MonitorOperatorCaptureInputs<K, S, N>(
    public val readouts: List<MonitorOperatorLiveReadout<K, S>>,
    public val panel: MonitorOperatorCameraPanel<K>? = null,
    public val fields: Map<K, MonitorCaptureField> = emptyMap(),
    public val columns: Int? = null,
    public val open: (K) -> Unit,
    public val dismiss: () -> Unit,
    public val isTop: (K) -> Boolean = { false },
    public val nativeQuick: (K) -> MonitorOperatorNativeCaptureQuick<N>? = { null },
    public val nativeCurrent: (K, N) -> Boolean = { _, _ -> false },
    public val nativeCommit: (K, N, String) -> Unit = { _, _, _ -> },
    public val previewChanged: (K, MonitorOperatorCapturePreview<K, N>?) -> Unit = { _, _ -> },
    public val commitAdmission: () -> Boolean = { true },
    public val quickActiveChanged: (Boolean) -> Unit = {},
    public val retireNative: () -> Unit = {},
)

@Stable public class MonitorOperatorCaptureState<K, N> {
    public val frames: MutableMap<K, MonitorRect> = mutableStateMapOf()
    public var preview: MonitorOperatorCapturePreview<K, N>? by mutableStateOf(null)
        private set
    public var revision: Long by mutableLongStateOf(0L)
        private set
    public var header: MonitorOperatorCaptureHeaderValues<K>? by mutableStateOf(null)
        private set
    internal var gestureOwner: MonitorQuickGestureOwner by mutableStateOf(MonitorQuickGestureOwner())
        private set
    private var notify: ((K, MonitorOperatorCapturePreview<K, N>?) -> Unit)? = null
    private var retireNative: (() -> Unit)? = null
    public fun retire(): Unit {
        clearPreview(); header = null; frames.clear(); revision += 1L
        gestureOwner = MonitorQuickGestureOwner(); retireNative?.invoke()
    }
    public fun publishHeader(key: K, title: String, subtitle: String): Unit {
        header = MonitorOperatorCaptureHeaderValues(key, title, subtitle)
    }
    internal fun clearHeader(key: K): Unit { if (header?.key == key) header = null }
    internal fun bindRetirement(action: () -> Unit): Unit { retireNative = action }
    internal fun show(value: MonitorOperatorCapturePreview<K, N>,
        notify: (K, MonitorOperatorCapturePreview<K, N>?) -> Unit): Unit {
        if (preview == value) return
        preview = value; this.notify = notify; notify(value.key, value)
    }
    internal fun clearPreview(): Unit {
        val previous = preview ?: return
        preview = null; val callback = notify; notify = null; callback?.invoke(previous.key, null)
    }
}

private data class CaptureReadoutSource<K, N>(val context: MonitorCaptureSourceIdentity, val revision: Long,
    val key: K, val field: MonitorCaptureField?, val native: MonitorOperatorNativeCaptureQuick<N>?)

private class CaptureReadoutActions(
    val quick: MonitorQuickControl?, val inert: Boolean, val open: () -> Unit,
    val commit: (MonitorQuickControl, String) -> Unit,
    val preview: @Composable (MonitorQuickPreview, Float) -> Unit,
    val hold: (() -> Unit)? = null,
)

/** Row and header use the same captured report and native release route. */
@Composable private fun <K, S, N> captureReadoutActions(
    readout: MonitorOperatorLiveReadout<K, S>, inputs: MonitorOperatorCaptureInputs<K, S, N>,
    control: MonitorControlModel, state: MonitorOperatorCaptureState<K, N>, source: MonitorCaptureSourceIdentity,
    enabled: Boolean, commandEnabled: Boolean, currentSource: () -> Boolean,
    owner: MonitorQuickGestureOwner, ownerId: String, portrait: Boolean,
): CaptureReadoutActions {
    val revision = state.revision
    val field = readout.field
    val native = if (field == null) inputs.nativeQuick(readout.id) else null
    val quick = (field?.quickControl() ?: native?.control)?.let {
        it.copy(enabled = it.enabled && commandEnabled && readout.quickEnabled,
            identity = CaptureReadoutSource(source, revision, readout.id, field, native))
    }
    // An unreported value with nothing to edit stays inert rather than opening an empty panel.
    val inert = MonitorCapturePresentation.readoutIsInert(readout.value, field, native?.control?.enabled,
        readout.quickEnabled, readout.action != null)
    val admitted by rememberUpdatedState(enabled && currentSource() && !inert)
    val commands by rememberUpdatedState(commandEnabled)
    val currentInputs by rememberUpdatedState(inputs)
    val currentReadout by rememberUpdatedState(readout)
    val currentQuick by rememberUpdatedState(quick)
    val currentNative by rememberUpdatedState(native)
    val sourceCurrent by rememberUpdatedState(currentSource)
    fun current(): Boolean = admitted && sourceCurrent() && state.revision == revision && state.gestureOwner === owner
    // The readout's own hold, only where no quick adjust owns the hold.
    val hold: (() -> Unit)? = if (commandEnabled && quick?.enabled != true && readout.holdAction != null) {
        {
            if (current() && commands && currentInputs.panel == null && currentInputs.commitAdmission()) {
                currentReadout.holdAction?.invoke()
            }
        }
    } else null
    return CaptureReadoutActions(quick, inert, hold = hold, open = {
        if (current() && state.preview == null && (owner.owner == null || owner.owner == ownerId)) {
            if (currentReadout.action != null) {
                if (!currentReadout.actionIsCommand || (commands && currentInputs.panel == null && currentInputs.commitAdmission())) currentReadout.action?.invoke()
            } else currentInputs.open(currentReadout.id)
        }
    }, commit = { captured, label ->
        if (current() && commands && currentInputs.panel == null && currentInputs.commitAdmission() &&
            captured == currentQuick && captured.enabled) {
            val value = currentReadout.field
            if (value != null) {
                value.choices.firstOrNull { it.label == label }?.let { control.commit(it, value) }
            } else {
                currentNative?.let { capturedNative ->
                    if (currentInputs.nativeCurrent(currentReadout.id, capturedNative.identity)) {
                        currentInputs.nativeCommit(currentReadout.id, capturedNative.identity, label)
                    }
                }
            }
        }
    }, preview = { value, maximum ->
        if (current() && commands && value.control == currentQuick && owner.owner == ownerId) {
            SideEffect {
                if (current() && value.control == currentQuick && owner.owner == ownerId) {
                    currentInputs.dismiss()
                    state.show(MonitorOperatorCapturePreview(readout.id, value, field, native?.identity), currentInputs.previewChanged)
                }
            }
            MonitorOperatorCaptureDrawer(readout.title, "drag to set", maximum,
                inputs.isTop(readout.id), portrait, compact = true, close = {}) {
                MonitorValueDrum(value.control.options, value.selection, markedValues = value.control.marked,
                    interactive = false, displayPosition = value.position, onSelect = {})
            }
        }
    })
}

/** The common body supplies the header label, while the shared recognizer retains the pointer. */
@Composable public fun <K, S, N> MonitorOperatorCaptureHeaderReadout(
    inputs: MonitorOperatorCaptureInputs<K, S, N>, control: MonitorControlModel,
    state: MonitorOperatorCaptureState<K, N>, source: MonitorCaptureSourceIdentity,
    readout: MonitorOperatorLiveReadout<K, S>, enabled: Boolean, commandEnabled: Boolean = true,
    currentSource: () -> Boolean, portrait: Boolean, modifier: Modifier = Modifier,
    fromTop: Boolean = true, ceilingY: Float? = null, bottomClearanceDp: Float = 0f,
    displayValue: String? = null, accessibilityLabel: String? = null,
    accessibilityValue: String? = null, content: @Composable () -> Unit,
): Unit {
    val owner = state.gestureOwner
    val ownerId = "header:${readout.id}"
    key(owner) {
        val actions = captureReadoutActions(readout, inputs, control, state, source,
            enabled, commandEnabled, currentSource, owner, ownerId, portrait)
        val currentInputs by rememberUpdatedState(inputs)
        SideEffect { state.bindRetirement(inputs.retireNative) }
        LaunchedEffect(owner.active) {
            if (state.gestureOwner === owner) {
                currentInputs.quickActiveChanged(owner.active != null)
                if (owner.active == null) state.clearPreview()
            }
        }
        DisposableEffect(owner, readout.id) {
            onDispose {
                if (state.gestureOwner === owner && (owner.owner == null || owner.owner == ownerId)) {
                    currentInputs.quickActiveChanged(false)
                    if (state.preview?.key == readout.id) state.clearPreview()
                }
            }
        }
        Box(modifier.monitorReadoutGesture(actions.quick,
            enabled && currentSource() && !actions.inert && (owner.owner == null || owner.owner == ownerId),
            actions.open, actions.commit, bottomClearanceDp, owner, ownerId, actions.preview,
            fromTop = fromTop, ceilingY = ceilingY,
            onPreviewBegin = { if (state.gestureOwner === owner) currentInputs.quickActiveChanged(true) },
            onHold = actions.hold).clearAndSetSemantics {
            contentDescription = accessibilityLabel ?: readout.title
            (accessibilityValue ?: displayValue ?: readout.value)?.let { stateDescription = it }
            if (actions.inert) disabled()
        }) {
            content()
        }
    }
}

/** The actual common strip uses the shared recognizer and never decodes native commands. */
@Composable public fun <K, S, N> MonitorOperatorCaptureStrip(
    inputs: MonitorOperatorCaptureInputs<K, S, N>, control: MonitorControlModel,
    state: MonitorOperatorCaptureState<K, N>, source: MonitorCaptureSourceIdentity,
    enabled: Boolean, commandEnabled: Boolean = true, currentSource: () -> Boolean,
    layout: MonitorFieldLayout, modifier: Modifier = Modifier,
    onCaptureFrame: (MonitorRect) -> Unit = {},
): Unit {
    val owner = state.gestureOwner
    key(owner) {
        val hideReadouts = state.preview?.let { !inputs.isTop(it.key) } == true
        val stripModifier = modifier.alpha(if (hideReadouts) 0f else 1f)
            .then(if (hideReadouts) Modifier.clearAndSetSemantics { } else Modifier)
        val density = LocalDensity.current
        val admitted by rememberUpdatedState(enabled && currentSource())
        val currentInputs by rememberUpdatedState(inputs)
        SideEffect { state.bindRetirement(inputs.retireNative) }
        val actions = inputs.readouts.associate { readout ->
            readout.id.toString() to captureReadoutActions(readout, inputs, control, state, source,
                enabled, commandEnabled, currentSource, owner, readout.id.toString(), layout.portrait)
        }
        inputs.readouts.forEach { readout ->
            DisposableEffect(state, readout.id) { onDispose { state.frames.remove(readout.id) } }
        }
        val itemModifiers = inputs.readouts.associate { readout ->
            readout.id.toString() to readout.itemModifier.monitorPickerPassthrough(admitted).onGloballyPositioned { coordinates ->
                if (currentSource()) {
                    val r = coordinates.boundsInRoot()
                    state.frames[readout.id] = with(density) { MonitorRect(r.left.toDp().value, r.top.toDp().value,
                        r.width.toDp().value, r.height.toDp().value) }
                }
            }
        }
        MonitorCameraValues(inputs.readouts.map { MonitorValue(it.id.toString(), it.title, it.value ?: "--",
            selected = inputs.panel?.key == it.id || state.preview?.key == it.id,
            annotation = it.annotation, valueIcon = it.icon, badgeIcon = it.badgeIcon,
            enabled = actions[it.id.toString()]?.inert != true, dimmed = it.dimmed) },
            admitted, layout.portrait, stripModifier.onGloballyPositioned { coordinates ->
                if (currentSource()) {
                    val r = coordinates.boundsInRoot()
                    onCaptureFrame(with(density) { MonitorRect(r.left.toDp().value, r.top.toDp().value,
                        r.width.toDp().value, r.height.toDp().value) })
                }
            }, itemModifier = { itemModifiers[it] ?: Modifier }, quickControl = { actions[it]?.quick }, onQuickCommit = { id, captured, label ->
                actions[id]?.commit?.invoke(captured, label)
            }, quickPreview = { id, preview, maximum ->
                actions[id]?.preview?.invoke(preview, maximum)
            }, onQuickActiveChange = { active ->
                if (state.gestureOwner === owner) {
                    currentInputs.quickActiveChanged(active)
                    if (!active && owner.active == null) state.clearPreview()
                }
            }, quickBottomClearanceDp = if (layout.portrait) layout.viewport.height - layout.system.y + 12f else 0f,
            gestureOwner = owner,
            columns = inputs.columns, onHold = { id -> actions[id]?.hold }, onOpen = { id ->
                actions[id]?.open?.invoke()
            })
    }
    DisposableEffect(state, source) { onDispose { state.retire() } }
}

/** The same projection is consumed by the real drawer body and geometry contract tests. */
public fun monitorOperatorCapturePlacement(layout: MonitorFieldLayout, top: Boolean, panelHeight: Float,
    safeLeading: Float = 0f, safeTrailing: Float = 0f, safeTop: Float = 0f,
    safeBottom: Float = 0f): MonitorLayoutPolicy.Panel = if (top) {
    MonitorLayoutPolicy.topPanel(panelHeight, layout.viewport.width, layout.viewport.height,
        safeLeading, safeTrailing, safeTop, safeBottom,
        if (layout.portrait) layout.status.maxY else null, if (layout.portrait) layout.system.y else null)
} else {
    MonitorLayoutPolicy.bottomPanel(panelHeight, layout.viewport.width, layout.viewport.height,
        safeLeading, safeTrailing, safeTop, safeBottom, if (layout.portrait) layout.system.y else null)
}

@Composable public fun <K, S, N> MonitorOperatorCapturePopup(
    inputs: MonitorOperatorCaptureInputs<K, S, N>, control: MonitorControlModel,
    state: MonitorOperatorCaptureState<K, N>, layout: MonitorFieldLayout,
    enabled: Boolean, commandEnabled: Boolean = true, currentSource: () -> Boolean,
    safeLeading: Float = 0f, safeTrailing: Float = 0f, safeTop: Float = 0f, safeBottom: Float = 0f,
    modifier: Modifier = Modifier, content: @Composable (K, MonitorRect, Boolean) -> Unit,
): Unit {
    val panel = inputs.panel ?: return
    if (!enabled || !currentSource()) return
    val density = LocalDensity.current
    var height by remember(panel.key) { mutableStateOf(86f) }
    val place = monitorOperatorCapturePlacement(layout, panel.top, height, safeLeading, safeTrailing, safeTop, safeBottom)
    val field = panel.field ?: inputs.fields[panel.key] ?: inputs.readouts.firstOrNull { it.id == panel.key }?.field
    val header = state.header?.takeIf { it.key == panel.key }
    DisposableEffect(state, panel.key) { onDispose { state.clearHeader(panel.key) } }
    Box(modifier.fillMaxSize()) {
        MonitorReadoutDismissBackdrop(onDismiss = { if (enabled && currentSource()) inputs.dismiss() })
        Box(Modifier.offset(place.x.dp, place.y.dp).width(place.width.dp).onGloballyPositioned {
            height = with(density) { it.size.height.toDp().value }
        }) {
            MonitorOperatorCaptureDrawer(header?.title ?: panel.title ?: field?.title ?: "Camera",
                header?.subtitle ?: panel.subtitle ?: field?.label ?: "Not set", place.maxHeight, panel.top, layout.portrait,
                close = { if (enabled && currentSource()) inputs.dismiss() }) {
                if (panel.chrome == MonitorOperatorCameraPanelChrome.DESCRIPTOR && field != null) {
                    MonitorCaptureDrum(control, field, enabled = commandEnabled && currentSource())
                } else {
                    CompositionLocalProvider(LocalMonitorCaptureCommandEnabled provides (commandEnabled && currentSource())) {
                        content(panel.key, MonitorRect(place.x, place.y, place.width, place.maxHeight), panel.top)
                    }
                }
            }
        }
    }
}

/** Header, material, reveal and scroll belong to the common owner, including held previews. */
@Composable public fun MonitorOperatorCaptureDrawer(title: String, subtitle: String, maximumHeight: Float,
    top: Boolean, portrait: Boolean, compact: Boolean = false, close: () -> Unit,
    content: @Composable () -> Unit): Unit {
    val paddingTop = MonitorLayoutPolicy.captureTopPadding(top, portrait, compact)
    val scroll = rememberScrollState()
    val topCorner = MonitorLayoutPolicy.capturePanelTopCorner(top, portrait).dp
    val bottomCorner = MonitorLayoutPolicy.capturePanelBottomCorner(top, portrait).dp
    MonitorCaptureReveal(fromTop = top) {
        Column(Modifier.fillMaxWidth().heightIn(max = maximumHeight.coerceAtLeast(0f).dp)
            .monitorMaterial(MonitorMaterial.Expanded,
                RoundedCornerShape(topStart = topCorner, topEnd = topCorner, bottomStart = bottomCorner, bottomEnd = bottomCorner))
            .monitorScrollFade(scroll).verticalScroll(scroll, enabled = !compact)
            .pointerInput(Unit) { detectTapGestures(onTap = {}) }
            .padding(horizontal = 14.dp).padding(top = paddingTop.dp,
                bottom = (if (compact) MonitorLayoutPolicy.compactCaptureBottomPadding(paddingTop) else if (top) 14f else 11f).dp),
            verticalArrangement = Arrangement.spacedBy(MonitorAssistPanelMetrics.PANEL_GAP_DP.dp)) {
            MonitorOperatorCaptureHeader(title, subtitle, close, showsClose = !compact)
            content()
            if (MonitorLayoutPolicy.showsCaptureGrabber(compact, top)) MonitorPanelGrabber()
        }
    }
}

@Composable public fun MonitorOperatorCaptureHeader(title: String, subtitle: String, onClose: () -> Unit,
    showsClose: Boolean = true, enabled: Boolean = true): Unit {
    val haptics = LocalOperatorHaptics.current
    Row(Modifier.fillMaxWidth().then(if (!showsClose) Modifier.height(MonitorLayoutPolicy.CAPTURE_HEADER_HEIGHT.dp) else Modifier),
        verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            Text(title, style = MonitorTypography.text(9f, FontWeight.SemiBold).copy(letterSpacing = 1.8.sp), maxLines = 1)
            Text(subtitle.uppercase(), style = MonitorTypography.text(8.5f).copy(letterSpacing = 1.19.sp),
                color = MonitorPalette.faint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = 2.dp))
        }
        if (showsClose) Box(Modifier.size(44.dp).monitorChromeClickable(enabled = enabled, onClick = onClose,
            onClickFeedback = { haptics.selection() }).testTag("monitor.capture.close")
            .semantics { contentDescription = "Close camera control" }, contentAlignment = Alignment.Center) {
            MonitorIcon(MonitorIcon.X, null, Modifier.size(13.dp), MonitorPalette.muted)
        }
    }
}
