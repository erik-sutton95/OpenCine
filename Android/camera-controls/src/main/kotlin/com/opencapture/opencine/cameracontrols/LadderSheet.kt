package com.opencapture.opencine.cameracontrols

import android.graphics.Paint as AndroidPaint
import android.graphics.Rect as AndroidRect
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalViewConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorLayoutPolicy
import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.opencine.appkit.LocalMonitorCaptureCommandEnabled
import com.opencapture.opencine.appkit.MonitorCaptureDrum
import com.opencapture.opencine.appkit.MonitorCaptureChoice
import com.opencapture.opencine.appkit.MonitorCaptureField
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.appkit.captureField
import com.opencapture.opencine.appkit.MonitorControlModel
import com.opencapture.opencine.vocabulary.CaptureLadder
import com.opencapture.opencine.vocabulary.CaptureLock
import com.opencapture.opencine.vocabulary.CaptureTint
import com.opencapture.opencine.vocabulary.LadderSheetPresentation
import com.opencapture.opencine.vocabulary.LadderStep
import com.opencapture.opencine.vocabulary.LadderTab
import com.opencapture.opencine.vocabulary.LadderWrite
import kotlin.math.roundToInt
import kotlinx.coroutines.withTimeoutOrNull

/** Retained editor and exact detents, or the host's existing label/unavailable surface. */
sealed interface LadderSheetDrum {
    data object Labels : LadderSheetDrum
    data class Field(val field: MonitorCaptureField, val choices: List<MonitorCaptureChoice>) : LadderSheetDrum
    data class Unavailable(val message: String?) : LadderSheetDrum
}

/** Observations and previews are values; the existing panel keeps its command and tab owners. */
class LadderSheetHost(
    val selectedTab: Int,
    val selection: String?,
    val drum: LadderSheetDrum,
    val previewPosition: Float? = null,
    val onSelectTab: (Int) -> Unit,
    val onCommitted: (SettingValue) -> Unit = {},
)

/** Whether the tabs and the drum accept input, and whether the lock line is showing. */
internal data class LadderGates(
    val tabsEnabled: Boolean,
    val drumEnabled: Boolean,
    val showBanner: Boolean,
)

/** [RECORDING] and [CAMERA_CONTROL] freeze the whole sheet. [AUTO] and [EXPOSURE_PROGRAM] freeze the drum. */
internal fun ladderGates(sheetLock: CaptureLock?, tabLock: CaptureLock?, enabled: Boolean): LadderGates {
    val sheetFrozen = sheetLock?.freezesSheet == true || tabLock?.freezesSheet == true
    val drumFrozen = sheetFrozen || sheetLock != null || tabLock != null
    return LadderGates(
        tabsEnabled = enabled && !sheetFrozen,
        drumEnabled = enabled && !drumFrozen,
        showBanner = sheetLock != null || tabLock != null,
    )
}

/** Writes fired when [tab] becomes the active tab. A blank landed value is not written. */
internal fun <K> ladderActivationWrites(tab: LadderTab<K>, landed: String): List<LadderWrite<K>> {
    val writes = mutableListOf<LadderWrite<K>>()
    tab.activate?.let { writes += it }
    if (tab.applyOnActivate && landed.isNotBlank()) writes += LadderWrite(tab.key, landed)
    return writes
}

/**
 * What the sheet's remembered tab, landed and applied values belong to: the tab keys and the tab
 * the host opens on. A new picker, a gained or lost tab, or a camera circuit change (a new initial
 * tab) starts fresh instead of carrying positional values onto other tabs.
 */
internal fun <K> ladderIdentity(presentation: LadderSheetPresentation<K>): Any =
    presentation.tabs.map { it.key } to presentation.initialTab

/**
 * The write a drum pick sends, or null when [value] is already applied. An unknown current applies
 * nothing, so picking the first label (where the drum seats an unknown value) still writes.
 */
internal fun <K> ladderPickWrite(tab: LadderTab<K>, applied: String, value: String): LadderWrite<K>? =
    if (value.isBlank() || value == applied) null else LadderWrite(tab.key, value)

/** A format pick's write: only a value on the tab's ladder, and only while the drum is open. */
internal fun <K> ladderFormatWrite(tab: LadderTab<K>, value: String, enabled: Boolean): LadderWrite<K>? =
    if (enabled && value in tab.ladder.values) LadderWrite(tab.key, value) else null

/** Labels on the drum: a host-grown ladder when the tab has one, otherwise the camera's list. */
internal fun <K> ladderOptions(tab: LadderTab<K>, landed: String): List<String> =
    tab.values?.invoke(landed) ?: tab.ladder.values

/**
 * Label-ladder sheet. Typed tabs draw [MonitorCaptureDrum] and commit through [control].
 * Label tabs draw the shared horizontal drum and report writes through [onWrite].
 * Existing capture panels pass their retained state and editor through [host].
 */
@Composable
fun <K> LadderSheet(
    presentation: LadderSheetPresentation<K>,
    enabled: Boolean,
    onWrite: (LadderWrite<K>) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    control: MonitorControlModel? = null,
    fromTop: Boolean = false,
    chromeless: Boolean = false,
    error: String? = null,
    unavailable: String? = null,
    onHold: (() -> Unit)? = null,
    /** A finger resting on (true) or leaving (false) a holdable sheet, so the host can name the hold. */
    onHoldPressing: ((Boolean) -> Unit)? = null,
    tintLabel: (CaptureTint) -> String = { "" },
    tintHelp: String? = null,
    footer: @Composable (LadderTab<K>) -> Unit = {},
    /** A recording-format sheet: the shared format picker (area, size, rate) over these exact choices,
     * each value a label from the tab's ladder. Twin of the SwiftUI sheet's `formats`. */
    formats: List<CaptureFormatChoice<String>>? = null,
    host: LadderSheetHost? = null,
) {
    if (presentation.tabs.isEmpty()) return
    val haptics = LocalOperatorHaptics.current
    val portrait = viewportIsPortrait()
    val last = presentation.tabs.lastIndex
    val identity = ladderIdentity(presentation)
    var selected by remember(identity) { mutableIntStateOf(presentation.initialTab.coerceIn(0, last)) }
    val index = (host?.selectedTab ?: selected).coerceIn(0, last)
    val tab = presentation.tabs[index]
    val landed = remember(identity) {
        mutableStateListOf(*presentation.tabs.map { it.ladder.current.orEmpty() }.toTypedArray())
    }
    val applied = remember(identity) {
        mutableStateListOf(*presentation.tabs.map { it.ladder.current.orEmpty() }.toTypedArray())
    }
    val commandEnabled = LocalMonitorCaptureCommandEnabled.current
    val gates = ladderGates(presentation.lock, tab.ladder.lock, enabled && commandEnabled)
    val hold = onHold.takeIf { commandEnabled }
    val shown = when {
        host != null -> host.selection.orEmpty()
        tab.ladder.lock != null -> tab.ladder.current.orEmpty()
        else -> landed.getOrElse(index) { tab.ladder.current.orEmpty() }
    }
    val options = ladderOptions(tab, shown)
    val holdTimeout = maxOf(LocalViewConfiguration.current.longPressTimeoutMillis, 450L)
    val top = MonitorLayoutPolicy.captureTopPadding(fromTop, portrait, compact = false)
    Column(
        modifier
            .then(if (chromeless) Modifier.fillMaxWidth() else Modifier.fillMaxSize())
            .testTag("ladder_sheet")
            .then(if (chromeless) Modifier else Modifier.pickerPanelGlass(capturePanelShape(fromTop, portrait)))
            .then(
                if (hold == null) Modifier else Modifier.pointerInput(holdTimeout, hold, onHoldPressing) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false)
                        // The callback that heard "pressing" hears the release, even on cancellation.
                        val pressing = onHoldPressing
                        pressing?.invoke(true)
                        try {
                            val released = withTimeoutOrNull(holdTimeout) { waitForUpOrCancellation() }
                            if (released == null) {
                                hold()
                                waitForUpOrCancellation()
                            }
                        } finally {
                            pressing?.invoke(false)
                        }
                    }
                },
            )
            .pointerInput(Unit) { detectTapGestures(onTap = {}) }
            .padding(horizontal = if (chromeless) 0.dp else 14.dp)
            .padding(top = if (chromeless) 0.dp else top.dp, bottom = if (chromeless) 0.dp else if (fromTop) 14.dp else 11.dp)
            .semantics {
                if (presentation.title.isNotEmpty()) contentDescription = "${presentation.title}. ${presentation.subtitle}"
            },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (!chromeless) SheetHeader(presentation.title, presentation.subtitle, onClose)
        if (!error.isNullOrBlank()) {
            Text(error, style = LiveType.ui(11f, FontWeight.Medium), color = LiveDesign.destructive, maxLines = 2)
        }
        if (!unavailable.isNullOrBlank()) {
            Text(unavailable, style = LiveType.ui(11f, FontWeight.Medium), color = LiveDesign.muted, maxLines = 2)
        }
        val lockBanner = presentation.lockBanner
        if (gates.showBanner && !lockBanner.isNullOrBlank()) {
            Row(
                Modifier.fillMaxWidth().background(LiveDesign.accentDim, ChromeShape).padding(horizontal = 12.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                MonitorIcon(MonitorIcon.LOCK, null, Modifier.size(14.dp), LiveDesign.accent.copy(alpha = 0.9f))
                Text(
                    lockBanner,
                    style = LiveType.ui(11.5f, FontWeight.Medium),
                    color = LiveDesign.accent.copy(alpha = 0.9f),
                    maxLines = 2,
                )
            }
        }
        Box(Modifier.fillMaxWidth().then(if (chromeless) Modifier else Modifier.weight(1f)), contentAlignment = Alignment.Center) {
            // A typed tab draws the session's field, limited to what the camera offers on it.
            val controlState = control?.state?.collectAsState()?.value
            val tint = tab.tint.takeIf { host == null }
            val hostedField = host?.drum as? LadderSheetDrum.Field
            val unavailableDrum = host?.drum as? LadderSheetDrum.Unavailable
            val core = hostedField?.let { it.field to it.choices }
                ?: tab.setting?.takeIf { host == null && tint == null && controlState != null }
                    ?.let { setting -> control?.captureField(setting.key)?.let { field ->
                        val offered = setting.offered.toSet()
                        field to field.choices.filter { it.value in offered }.ifEmpty { field.choices }
                    } }
            when {
                unavailableDrum != null -> unavailableDrum.message?.let {
                    Text(it, color = LiveDesign.muted)
                }
                hostedField != null && control == null -> Unit
                formats != null -> {
                    val source = controlState?.snapshot?.let { it.session to it.epoch }
                    CaptureFormatPicker(
                        choices = formats, current = tab.ladder.current, enabled = gates.drumEnabled,
                        sourceIdentity = source ?: identity,
                        isCurrent = { control?.state?.value?.snapshot?.let { it.session to it.epoch } == source },
                    ) { choice ->
                        ladderFormatWrite(tab, choice.value, gates.drumEnabled)?.let(onWrite)
                    }
                }
                tint != null -> TintPad(
                    tint = tint,
                    enabled = gates.drumEnabled,
                    labelOf = tintLabel,
                    help = tintHelp,
                    onChange = { next ->
                        val text = tintLabel(next)
                        if (gates.drumEnabled && text.isNotBlank()) onWrite(LadderWrite(tab.key, text))
                    },
                )
                core != null && control != null -> {
                    val (field, choices) = core
                    MonitorCaptureDrum(
                        control, field, enabled = gates.drumEnabled, modifier = Modifier.fillMaxWidth(),
                        choices = choices, marked = tab.ladder.marked,
                        previewPosition = host?.previewPosition,
                        previewSelection = host?.takeIf { it.previewPosition != null }?.selection,
                        onDetent = { if (host == null) haptics.confirm() },
                        onCommitted = { value ->
                            val label = choices.firstOrNull { it.value == value }?.label ?: return@MonitorCaptureDrum
                            if (index in landed.indices) landed[index] = label
                            host?.onCommitted?.invoke(value)
                        },
                    )
                }
                else -> LabelDrum(
                    options = options,
                    // Unknown stays blank: the drum seats on its first label without claiming it.
                    selection = shown,
                    marked = tab.ladder.marked,
                    enabled = gates.drumEnabled,
                    steps = tab.steps?.invoke(shown),
                    stepsHint = tab.stepsHint,
                    previewPosition = host?.previewPosition,
                    onSelect = { value ->
                        if (!gates.drumEnabled || value.isBlank()) return@LabelDrum
                        if (host != null) {
                            if (host.previewPosition == null) onWrite(LadderWrite(tab.key, value))
                            return@LabelDrum
                        }
                        if (index in landed.indices) landed[index] = value
                        ladderPickWrite(tab, applied.getOrNull(index).orEmpty(), value)?.let { write ->
                            if (index in applied.indices) applied[index] = value
                            onWrite(write)
                        }
                    },
                    onStep = { step ->
                        val value = step.value ?: return@LabelDrum
                        if (!gates.drumEnabled) return@LabelDrum
                        if (step.lands && index in landed.indices) {
                            landed[index] = value
                            if (index in applied.indices) applied[index] = value
                        }
                        onWrite(LadderWrite(tab.key, value))
                    },
                )
            }
        }
        if (presentation.tabs.size > 1) {
            ModeBar(
                tabs = presentation.tabs.map { it.label },
                selected = index,
                enabled = gates.tabsEnabled,
                details = presentation.tabs.map { it.detail },
                disabled = presentation.tabs.mapIndexedNotNull { i, candidate -> if (candidate.disabled) i else null }.toSet(),
            ) { next ->
                val candidate = presentation.tabs.getOrNull(next) ?: return@ModeBar
                if (next == index || candidate.disabled || !gates.tabsEnabled) return@ModeBar
                if (host != null) {
                    if (host.previewPosition == null) host.onSelectTab(next)
                    return@ModeBar
                }
                selected = next
                val landedValue = when {
                    candidate.ladder.lock != null -> candidate.ladder.current.orEmpty()
                    else -> landed.getOrElse(next) { candidate.ladder.current.orEmpty() }
                }
                ladderActivationWrites(candidate, landedValue).forEach { write ->
                    if (write.key == candidate.key && next in applied.indices) applied[next] = write.value
                    onWrite(write)
                }
            }
        }
        footer(tab)
    }
}

@Composable
private fun LabelDrum(
    options: List<String>,
    selection: String,
    marked: Set<String>,
    enabled: Boolean,
    steps: Pair<LadderStep, LadderStep>?,
    stepsHint: String? = null,
    previewPosition: Float? = null,
    onSelect: (String) -> Unit,
    onStep: (LadderStep) -> Unit,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (steps != null) StepButton(steps.first, enabled, onStep)
        Box(Modifier.weight(1f)) {
            val preview = LocalCapturePreview.current
            val haptics = LocalOperatorHaptics.current
            com.opencapture.monitorui.MonitorValueDrum(
                preview?.control?.options ?: options, preview?.selection ?: selection,
                markedValues = preview?.control?.marked ?: marked,
                interactive = enabled && preview == null && previewPosition == null,
                displayPosition = preview?.position ?: previewPosition,
                dimDisabled = preview == null && previewPosition == null,
                hint = stepsHint.takeIf { steps != null },
                onDetent = { haptics.confirm() },
                onSelect = { value ->
                    if (enabled && preview == null && previewPosition == null) onSelect(value)
                })
        }
        if (steps != null) StepButton(steps.second, enabled, onStep)
    }
}

@Composable
private fun StepButton(step: LadderStep, enabled: Boolean, onStep: (LadderStep) -> Unit) {
    val live = enabled && step.value != null
    Column(
        Modifier
            .widthIn(min = 52.dp)
            .heightIn(min = 44.dp)
            .alpha(if (live) 1f else 0.35f)
            .background(if (step.selected) LiveDesign.accentDim else LiveDesign.surface, ChromeShape)
            .border(1.dp, if (step.selected) LiveDesign.accent else LiveDesign.hairline, ChromeShape)
            .chromeClickable(enabled = live) { if (live) onStep(step) }
            .semantics { contentDescription = step.description }
            .padding(horizontal = 8.dp, vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            step.label,
            style = LiveType.ui(11f, FontWeight.SemiBold),
            color = if (step.selected) LiveDesign.accent else LiveDesign.text,
            maxLines = 1,
            textAlign = TextAlign.Center,
        )
    }
}

/** Two-axis fine tune. [CaptureTint.amberBlue] null is a green/magenta-only pad. */
@Composable
private fun TintPad(
    tint: CaptureTint,
    enabled: Boolean,
    labelOf: (CaptureTint) -> String,
    help: String?,
    onChange: (CaptureTint) -> Unit,
) {
    val density = LocalDensity.current
    val sidePx = with(density) { 108.dp.toPx() }
    val range = tint.range
    val horizontal = tint.amberBlue != null
    var ab by remember(tint.amberBlue, tint.greenMagenta) { mutableIntStateOf(tint.amberBlue ?: 0) }
    var gm by remember(tint.amberBlue, tint.greenMagenta) { mutableIntStateOf(tint.greenMagenta) }
    fun emit(nextAb: Int, nextGm: Int) {
        val clampedAb = nextAb.coerceIn(range.first, range.last)
        val clampedGm = nextGm.coerceIn(range.first, range.last)
        ab = clampedAb
        gm = clampedGm
        onChange(CaptureTint(clampedGm, if (horizontal) clampedAb else null, range))
    }
    val shown = labelOf(CaptureTint(gm, if (horizontal) ab else null, range)).ifBlank { " " }
    Row(
        Modifier.fillMaxWidth().wrapContentHeight().alpha(if (enabled) 1f else 0.45f)
            .semantics { contentDescription = "Tint $shown" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (horizontal) {
                TintArrow(MonitorIcon.CHEVRON_LEFT, enabled, "Shift toward blue") { emit(ab - 1, gm) }
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                TintArrow(MonitorIcon.CHEVRON_UP, enabled, "Shift toward green") { emit(ab, gm + 1) }
                Box(
                    Modifier.size(108.dp)
                        .background(LiveDesign.surface, RoundedCornerShape(12.dp))
                        .border(1.dp, LiveDesign.hairline, RoundedCornerShape(12.dp))
                        .pointerInput(enabled, horizontal) {
                            if (!enabled) return@pointerInput
                            detectTapGestures(onDoubleTap = { emit(0, 0) })
                        }
                        .pointerInput(enabled, horizontal, range) {
                            if (!enabled) return@pointerInput
                            detectDragGestures(
                                onDrag = { change, _ ->
                                    change.consume()
                                    val x = (change.position.x / sidePx).coerceIn(0f, 1f)
                                    val y = (change.position.y / sidePx).coerceIn(0f, 1f)
                                    if (horizontal) ab = cellFromNormalized(x, range)
                                    gm = cellFromNormalized(1f - y, range)
                                },
                                onDragEnd = { emit(ab, gm) },
                                onDragCancel = { emit(ab, gm) },
                            )
                        },
                ) {
                    Canvas(Modifier.fillMaxSize()) { drawTintCrosshair() }
                    val thumbX = if (horizontal) thumbOffset(ab, range, sidePx) else sidePx / 2f
                    val thumbY = sidePx - thumbOffset(gm, range, sidePx)
                    val half = with(density) { 6.5.dp.toPx() }
                    Box(
                        Modifier.offset { IntOffset((thumbX - half).roundToInt(), (thumbY - half).roundToInt()) }
                            .size(13.dp)
                            .shadow(3.dp, CircleShape)
                            .background(LiveDesign.accent, CircleShape),
                    )
                }
                TintArrow(MonitorIcon.CHEVRON_DOWN, enabled, "Shift toward magenta") { emit(ab, gm - 1) }
            }
            if (horizontal) {
                TintArrow(MonitorIcon.CHEVRON_RIGHT, enabled, "Shift toward amber") { emit(ab + 1, gm) }
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(
                shown,
                style = LiveType.ui(17f, FontWeight.SemiBold),
                color = if (shown == "Neutral") LiveDesign.muted else LiveDesign.accent,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!help.isNullOrBlank()) {
                Text(help, style = LiveType.ui(11f), color = LiveDesign.muted)
            }
        }
    }
}

@Composable
private fun TintArrow(icon: MonitorIcon, enabled: Boolean, description: String, onClick: () -> Unit) {
    Box(
        Modifier.size(28.dp).background(LiveDesign.glassBright, CircleShape)
            .chromeClickable(enabled = enabled, onClick = { if (enabled) onClick() })
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(icon, null, Modifier.size(18.dp), LiveDesign.text)
    }
}

private fun DrawScope.drawTintCrosshair() {
    val stroke = 1.dp.toPx()
    val inset = 18.dp.toPx()
    val edge = 10.dp.toPx()
    drawLine(LiveDesign.hairline, Offset(size.width / 2f, inset), Offset(size.width / 2f, size.height - inset), stroke)
    drawLine(LiveDesign.hairline, Offset(inset, size.height / 2f), Offset(size.width - inset, size.height / 2f), stroke)
    drawAxisLetter("G", Color.Green.copy(alpha = 0.85f), size.width / 2f, edge)
    drawAxisLetter("M", Color(0xFFFF2D95).copy(alpha = 0.85f), size.width / 2f, size.height - edge)
    drawAxisLetter("B", Color.Blue.copy(alpha = 0.85f), edge, size.height / 2f)
    drawAxisLetter("A", Color(0xFFFF9500).copy(alpha = 0.85f), size.width - edge, size.height / 2f)
}

private fun DrawScope.drawAxisLetter(letter: String, color: Color, x: Float, y: Float) {
    val paint = AndroidPaint(AndroidPaint.ANTI_ALIAS_FLAG).apply {
        this.color = color.toArgb()
        textSize = 9.sp.toPx()
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textAlign = AndroidPaint.Align.CENTER
    }
    val bounds = AndroidRect()
    paint.getTextBounds(letter, 0, letter.length, bounds)
    val baseline = y - (bounds.top + bounds.bottom) / 2f
    drawContext.canvas.nativeCanvas.drawText(letter, x, baseline, paint)
}

private fun thumbOffset(value: Int, range: IntRange, sidePx: Float): Float {
    val span = (range.last - range.first).toFloat().coerceAtLeast(1f)
    return (value.coerceIn(range.first, range.last) - range.first) / span * sidePx
}

private fun cellFromNormalized(t: Float, range: IntRange): Int {
    val clamped = t.coerceIn(0f, 1f)
    val value = range.first + clamped * (range.last - range.first)
    return value.roundToInt().coerceIn(range.first, range.last)
}
