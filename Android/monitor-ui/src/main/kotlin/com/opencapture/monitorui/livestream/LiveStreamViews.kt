package com.opencapture.monitorui.livestream

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.disabled
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.LiveStreamActions
import com.opencapture.monitorui.LiveStreamCopy
import com.opencapture.monitorui.LiveStreamEligibility
import com.opencapture.monitorui.LiveStreamEnd
import com.opencapture.monitorui.LiveStreamKeyState
import com.opencapture.monitorui.LiveStreamHealth
import com.opencapture.monitorui.LiveStreamPhase
import com.opencapture.monitorui.LiveStreamQuality
import com.opencapture.monitorui.LiveStreamQualityOption
import com.opencapture.monitorui.LiveStreamServiceOption
import com.opencapture.monitorui.LiveStreamState
import com.opencapture.monitorui.LiveStreamStatusState
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMaterial
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.isRunning
import com.opencapture.monitorui.liveStreamPillState
import com.opencapture.monitorui.monitorMaterial
import com.opencapture.monitorui.monitorReadoutShadow
import com.opencapture.monitorui.settings.MonitorSettingsActionPill
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsRowCard
import com.opencapture.monitorui.settings.MonitorSettingsSwitchInlineRow
import com.opencapture.monitorui.settings.MonitorSettingsValueText
import kotlinx.coroutines.launch

/** Accessibility identifiers from `docs/streaming/ui-contract.md`, as Compose test tags. */
object LiveStreamIds {
    const val SERVICE = "monitor.livestream.service"
    const val KEY_HINT = "monitor.livestream.keyHint"
    const val SERVER = "monitor.livestream.server"
    const val PLAIN_WARNING = "monitor.livestream.plainWarning"
    const val SERVER_PROBLEM = "monitor.livestream.serverProblem"
    const val KEY = "monitor.livestream.key"
    const val KEY_PASTE = "monitor.livestream.key.paste"
    const val KEY_SAVE = "monitor.livestream.key.save"
    const val KEY_SAVED = "monitor.livestream.key.saved"
    const val KEY_REMOVE = "monitor.livestream.key.remove"
    const val KEY_UNAVAILABLE = "monitor.livestream.key.unavailable"
    const val QUALITY = "monitor.livestream.quality"
    const val QUALITY_CHOICE = "monitor.livestream.qualityChoice"
    const val QUALITY_DETAIL = "monitor.livestream.qualityDetail"
    const val CAMERA_STATUS = "monitor.livestream.cameraStatus"
    const val CAMERA_RETRY = "monitor.livestream.cameraRetry"
    const val VERTICAL_NOTE = "monitor.livestream.verticalNote"
    const val SHOW_ON_MONITOR = "monitor.livestream.showOnMonitor"
    const val ELIGIBILITY = "monitor.livestream.eligibility"
    const val LOCKED_WHILE_LIVE = "monitor.livestream.lockedWhileLive"
    const val GO_LIVE = "monitor.livestream.goLive"
    const val STATUS = "monitor.livestream.status"
    const val NOTICE = "monitor.livestream.notice"
    const val NOTICE_DISMISS = "monitor.livestream.notice.dismiss"
    const val RESTART = "monitor.livestream.restart"
    const val WARNING = "monitor.livestream.warning"
    const val PILL = "monitor.livestream.pill"
    const val PILL_STOP = "monitor.livestream.pill.stop"
}

private val noteStyle get() = MonitorTypography.text(12f, FontWeight.Normal)
private val warningColor = Color(0xFFF0B23C)

/** The Live stream card on the Sharing tab. Values in, actions out; the key is never shown. */
@Composable
fun LiveStreamSettingsCard(state: LiveStreamState, actions: LiveStreamActions) {
    val selected = state.selected ?: return
    val running = state.phase.isRunning
    var removing by remember { mutableStateOf(false) }
    MonitorSettingsRowCard(LiveStreamCopy.CARD_TITLE) {
        MonitorSettingsInlineRow(LiveStreamCopy.SERVICE, showTopDivider = false, stacked = true) {
            Box(Modifier.alpha(if (running) 0.45f else 1f)) {
                MonitorSettingsChoices(state.services, selected, compact = true, fillWidth = true,
                    testTag = LiveStreamIds.SERVICE, title = LiveStreamServiceOption::name) {
                    if (!running) actions.selectService(it.id)
                }
            }
        }
        Note(selected.keyHint, LiveStreamIds.KEY_HINT, MonitorPalette.muted)
        if (selected.needsServer) {
            MonitorSettingsInlineRow(LiveStreamCopy.SERVER, stacked = true) {
                LiveStreamField(
                    value = state.server,
                    placeholder = if (selected.acceptsPlainServer) LiveStreamCopy.SERVER_PLACEHOLDER_PLAIN else LiveStreamCopy.SERVER_PLACEHOLDER,
                    tag = LiveStreamIds.SERVER, label = LiveStreamCopy.SERVER, secret = false,
                    enabled = !running && state.keyState != LiveStreamKeyState.SAVED,
                    onValueChange = actions::setServer,
                )
            }
            if (state.plainServer) Note(LiveStreamCopy.PLAIN_SERVER_WARNING, LiveStreamIds.PLAIN_WARNING, warningColor)
        }
        state.problem?.let { Note(it, LiveStreamIds.SERVER_PROBLEM, MonitorPalette.recording) }
        KeyRow(state, running, actions, onRemove = { removing = true })
        val chosenQuality = state.selectedQuality
        if (state.showsQualityPicker && chosenQuality != null) {
            MonitorSettingsInlineRow(LiveStreamCopy.QUALITY, stacked = true) {
                Box(Modifier.alpha(if (running) 0.45f else 1f)) {
                    MonitorSettingsChoices(state.qualityOptions, chosenQuality, compact = true, fillWidth = true,
                        testTag = LiveStreamIds.QUALITY_CHOICE, title = LiveStreamQualityOption::title) {
                        if (!running && it.enabled) actions.selectQuality(it.id)
                    }
                }
            }
            Box(Modifier.testTag(LiveStreamIds.QUALITY)) { MonitorSettingsValueText(LiveStreamCopy.quality(state.quality)) }
            state.qualityDetail?.let { Note(it, LiveStreamIds.QUALITY_DETAIL, MonitorPalette.muted) }
        } else {
            MonitorSettingsInlineRow(LiveStreamCopy.QUALITY) {
                Box(Modifier.testTag(LiveStreamIds.QUALITY)) { MonitorSettingsValueText(LiveStreamCopy.quality(state.quality)) }
            }
        }
        if (selected.vertical) {
            Note(LiveStreamCopy.verticalNote(state.sourceHeight ?: 720), LiveStreamIds.VERTICAL_NOTE, MonitorPalette.muted)
        }
        MonitorSettingsSwitchInlineRow(LiveStreamCopy.SHOW_ON_MONITOR, state.showOnMonitor,
            testTag = LiveStreamIds.SHOW_ON_MONITOR) { actions.setShowOnMonitor(!state.showOnMonitor) }
        LiveStreamCopy.eligibilityLong(state.eligibility)?.let { Note(it, LiveStreamIds.ELIGIBILITY, MonitorPalette.muted) }
        if (running) Note(LiveStreamCopy.LOCKED_WHILE_LIVE, LiveStreamIds.LOCKED_WHILE_LIVE, MonitorPalette.muted)
    }
    if (removing) {
        AlertDialog(onDismissRequest = { removing = false },
            title = { Text(LiveStreamCopy.REMOVE_TITLE) },
            text = { Text(LiveStreamCopy.removeMessage(selected.name)) },
            confirmButton = {
                TextButton(onClick = { removing = false; actions.removeKey() }) {
                    Text(LiveStreamCopy.REMOVE, color = MonitorPalette.recording)
                }
            },
            dismissButton = { TextButton(onClick = { removing = false }) { Text(LiveStreamCopy.CANCEL) } })
    }
}

@Composable
private fun KeyRow(state: LiveStreamState, running: Boolean, actions: LiveStreamActions, onRemove: () -> Unit) {
    when (state.keyState) {
        LiveStreamKeyState.SAVED -> MonitorSettingsInlineRow(LiveStreamCopy.STREAM_KEY) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.testTag(LiveStreamIds.KEY_SAVED)) { MonitorSettingsValueText(LiveStreamCopy.SAVED) }
                MonitorSettingsActionPill(LiveStreamCopy.REMOVE, enabled = !running,
                    modifier = Modifier.testTag(LiveStreamIds.KEY_REMOVE), onClick = onRemove)
            }
        }
        LiveStreamKeyState.UNAVAILABLE -> Note(LiveStreamCopy.KEY_UNAVAILABLE, LiveStreamIds.KEY_UNAVAILABLE, MonitorPalette.muted)
        LiveStreamKeyState.ABSENT -> {
            var draft by remember { mutableStateOf("") }
            val clipboard = LocalClipboard.current
            val scope = rememberCoroutineScope()
            MonitorSettingsInlineRow(LiveStreamCopy.STREAM_KEY, stacked = true) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        LiveStreamField(draft, LiveStreamCopy.KEY_PLACEHOLDER, LiveStreamIds.KEY, LiveStreamCopy.STREAM_KEY,
                            secret = true, enabled = !running) { draft = it }
                    }
                    MonitorSettingsActionPill(LiveStreamCopy.PASTE, enabled = !running,
                        modifier = Modifier.testTag(LiveStreamIds.KEY_PASTE)) {
                        scope.launch {
                            val text = clipboard.getClipEntry()?.clipData?.takeIf { it.itemCount > 0 }
                                ?.getItemAt(0)?.text?.toString()
                            if (text != null) draft = text.trim()
                        }
                    }
                    MonitorSettingsActionPill(LiveStreamCopy.SAVE, enabled = !running && draft.isNotBlank(),
                        modifier = Modifier.testTag(LiveStreamIds.KEY_SAVE)) {
                        actions.saveKey(draft)
                        draft = ""
                    }
                }
            }
        }
    }
}

/**
 * Shows a non-empty secret as eight bullets whatever its length, so neither the key nor its
 * length is ever on screen.
 */
internal object FixedLengthMask : VisualTransformation {
    const val BULLETS = 8

    override fun filter(text: AnnotatedString): TransformedText {
        if (text.isEmpty()) return TransformedText(text, OffsetMapping.Identity)
        val length = text.length
        return TransformedText(AnnotatedString("•".repeat(BULLETS)), object : OffsetMapping {
            override fun originalToTransformed(offset: Int): Int = if (offset >= length) BULLETS else minOf(offset, BULLETS)
            override fun transformedToOriginal(offset: Int): Int = if (offset >= BULLETS) length else minOf(offset, length)
        })
    }
}

@Composable
private fun LiveStreamField(
    value: String,
    placeholder: String,
    tag: String,
    label: String,
    secret: Boolean,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
) {
    val shape = RoundedCornerShape(8.dp)
    BasicTextField(value, onValueChange = onValueChange, enabled = enabled, singleLine = true,
        textStyle = MonitorTypography.text(14f, FontWeight.Normal).copy(color = MonitorPalette.text),
        keyboardOptions = KeyboardOptions(keyboardType = if (secret) KeyboardType.Password else KeyboardType.Uri,
            autoCorrectEnabled = false),
        visualTransformation = if (secret) FixedLengthMask else VisualTransformation.None,
        cursorBrush = SolidColor(MonitorPalette.accent),
        modifier = Modifier.fillMaxWidth().testTag(tag).semantics { contentDescription = label }
            .alpha(if (enabled) 1f else 0.45f),
        decorationBox = { field ->
            Box(Modifier.fillMaxWidth().background(MonitorPalette.background.copy(alpha = 0.5f), shape)
                .border(1.dp, MonitorPalette.border, shape).padding(horizontal = 10.dp, vertical = 9.dp)) {
                if (value.isEmpty()) Text(placeholder, style = noteStyle, color = MonitorPalette.faint)
                field()
            }
        })
}

@Composable
private fun Note(text: String, tag: String, color: Color) {
    Text(text, style = noteStyle, color = color, modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp).testTag(tag))
}

/** What the Go live control shows in each state (title, caption, label, hint), per the contract. */
data class LiveStreamControlLook(
    val title: String,
    val enabled: Boolean,
    val caption: String?,
    val label: String,
    val hint: String?,
    val live: Boolean,
)

fun liveStreamControlLook(state: LiveStreamState): LiveStreamControlLook {
    val service = state.selected?.name.orEmpty()
    return when (val phase = state.phase) {
        LiveStreamPhase.Connecting -> LiveStreamControlLook(LiveStreamCopy.CONNECTING, true, null,
            LiveStreamCopy.connectingLabel(service), LiveStreamCopy.ENDS_THE_STREAM, false)
        LiveStreamPhase.Live -> {
            val elapsed = state.status?.elapsedSeconds ?: 0
            LiveStreamControlLook(LiveStreamCopy.liveTitle(elapsed), true, null, LiveStreamCopy.liveLabel(elapsed),
                LiveStreamCopy.ENDS_THE_STREAM, true)
        }
        is LiveStreamPhase.Reconnecting -> LiveStreamControlLook(LiveStreamCopy.RECONNECTING, true, null,
            LiveStreamCopy.reconnectingLabel(phase.attempt), LiveStreamCopy.ENDS_THE_STREAM, false)
        LiveStreamPhase.Idle, is LiveStreamPhase.Ended ->
            if (state.eligibility == LiveStreamEligibility.ALLOWED) {
                LiveStreamControlLook(LiveStreamCopy.GO_LIVE, true, null, LiveStreamCopy.GO_LIVE,
                    LiveStreamCopy.goLiveHint(service), false)
            } else {
                LiveStreamControlLook(LiveStreamCopy.GO_LIVE, false, LiveStreamCopy.eligibilityShort(state.eligibility),
                    LiveStreamCopy.GO_LIVE_UNAVAILABLE, LiveStreamCopy.eligibilityLong(state.eligibility), false)
            }
    }
}

/**
 * The Go live control with its one-line status, notice and warnings, end aligned so it hangs
 * under the monitor's status row (see `LiveStreamOverlayPlacement`). Idle it is a glass "Go live"
 * capsule; live a red capsule with the elapsed time and a stop glyph (tapping asks the same stop
 * confirmation), with `1080p · 6 Mbps · good` under it. [onStart] runs after the start
 * confirmation (composition may ask for the microphone first); it defaults to [LiveStreamActions.goLive].
 */
@Composable
fun LiveStreamMonitorControls(
    state: LiveStreamState,
    actions: LiveStreamActions,
    modifier: Modifier = Modifier,
    onStart: () -> Unit = actions::goLive,
) {
    var confirmingStart by remember { mutableStateOf(false) }
    var confirmingStop by remember { mutableStateOf(false) }
    Column(modifier.widthIn(max = 260.dp), horizontalAlignment = Alignment.End,
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (state.showsControl) {
            GoLiveControl(liveStreamControlLook(state), stops = state.phase.isRunning) {
                if (state.phase.isRunning) confirmingStop = true else confirmingStart = true
            }
        }
        if (state.phase.isRunning) state.status?.let { StatusLine(it, state.quality) }
        state.cameraStatus?.let { camera ->
            Bubble(Modifier.testTag(LiveStreamIds.CAMERA_STATUS)) {
                Text(LiveStreamCopy.cameraStatus(camera), style = noteStyle, color = MonitorPalette.text)
                if (camera.offersRetry) {
                    MonitorSettingsActionPill(LiveStreamCopy.CAMERA_RETRY,
                        modifier = Modifier.testTag(LiveStreamIds.CAMERA_RETRY), onClick = actions::retryCamera)
                }
            }
        }
        val ended = state.phase as? LiveStreamPhase.Ended
        state.notice?.let { notice ->
            Bubble(Modifier.testTag(LiveStreamIds.NOTICE)) {
                Text(notice, style = noteStyle, color = MonitorPalette.text)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (ended?.end == LiveStreamEnd.Background) {
                        MonitorSettingsActionPill(LiveStreamCopy.RESTART, modifier = Modifier.testTag(LiveStreamIds.RESTART),
                            onClick = actions::restart)
                    }
                    MonitorSettingsActionPill(LiveStreamCopy.DISMISS, tint = MonitorPalette.muted,
                        background = Color.Transparent, modifier = Modifier.testTag(LiveStreamIds.NOTICE_DISMISS),
                        onClick = actions::dismissNotice)
                }
            }
        }
        if (state.phase.isRunning) {
            for (warning in state.warnings.sorted()) {
                Bubble(Modifier.testTag(LiveStreamIds.WARNING)) {
                    Text(LiveStreamCopy.warning(warning), style = noteStyle, color = warningColor)
                }
            }
        }
    }
    val service = state.selected?.name.orEmpty()
    if (confirmingStart) {
        AlertDialog(onDismissRequest = { confirmingStart = false },
            title = { Text(LiveStreamCopy.startTitle(service)) },
            text = { Text(LiveStreamCopy.startMessage(state.quality, state.plainServer)) },
            confirmButton = {
                if (state.networkChoices.size > 1) {
                    Column(horizontalAlignment = Alignment.End) {
                        for (network in state.networkChoices) {
                            TextButton(onClick = { confirmingStart = false; actions.goLive(network.id) }) {
                                Text(LiveStreamCopy.startOnNetwork(network.name))
                            }
                        }
                    }
                } else {
                    TextButton(onClick = { confirmingStart = false; onStart() }) { Text(LiveStreamCopy.GO_LIVE) }
                }
            },
            dismissButton = { TextButton(onClick = { confirmingStart = false }) { Text(LiveStreamCopy.CANCEL) } })
    }
    if (confirmingStop) {
        AlertDialog(onDismissRequest = { confirmingStop = false },
            title = { Text(LiveStreamCopy.STOP_TITLE) },
            text = { Text(LiveStreamCopy.STOP_MESSAGE) },
            confirmButton = {
                TextButton(onClick = { confirmingStop = false; actions.stop() }) {
                    Text(LiveStreamCopy.END_STREAM, color = MonitorPalette.recording)
                }
            },
            dismissButton = { TextButton(onClick = { confirmingStop = false }) { Text(LiveStreamCopy.KEEP_STREAMING) } })
    }
}

@Composable
private fun GoLiveControl(look: LiveStreamControlLook, stops: Boolean, onTap: () -> Unit) {
    val shape = CircleShape
    val ink = if (look.live) Color.White else if (look.enabled) MonitorPalette.text else MonitorPalette.muted
    Column(horizontalAlignment = Alignment.End) {
        Row(
            Modifier
                .defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
                .testTag(LiveStreamIds.GO_LIVE)
                .clearAndSetSemantics {
                    contentDescription = look.label
                    role = Role.Button
                    if (look.enabled) onClick(label = look.hint) { onTap(); true } else disabled()
                }
                .clickable(enabled = look.enabled, onClick = onTap),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.End,
        ) {
            Row(
                (if (look.live) Modifier.background(MonitorPalette.recording, shape)
                else Modifier.monitorMaterial(MonitorMaterial.Compact, shape))
                    .border(1.dp, if (look.live) MonitorPalette.recording else MonitorPalette.border, shape)
                    .padding(start = 12.dp, end = if (stops) 4.dp else 14.dp, top = 4.dp, bottom = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                if (!look.live) MonitorIcon(MonitorIcon.RADIO, null, Modifier.size(15.dp), ink)
                Text(look.title, style = MonitorTypography.readout(13f, FontWeight.SemiBold), color = ink,
                    maxLines = 1, modifier = Modifier.padding(vertical = 4.dp))
                // The inline stop: part of the one control, so it asks the same stop confirmation.
                if (stops) Box(Modifier.size(26.dp).background(Color.White.copy(alpha = if (look.live) .22f else .12f), shape),
                    contentAlignment = Alignment.Center) {
                    Box(Modifier.size(9.dp).background(ink, RoundedCornerShape(2.dp)))
                }
            }
        }
        look.caption?.let { Text(it, style = noteStyle, color = MonitorPalette.muted) }
    }
}

/** The one muted line under the live control: quality, bitrate, drops and link health. */
@Composable
private fun StatusLine(status: LiveStreamStatusState, quality: LiveStreamQuality?) {
    val label = LiveStreamCopy.statusLabel(status)
    val dot = when (status.health) {
        LiveStreamHealth.GOOD -> Color(0xFF4CD964)
        LiveStreamHealth.CONGESTED -> warningColor
        LiveStreamHealth.OFFLINE -> MonitorPalette.recording
    }
    Row(
        Modifier
            .testTag(LiveStreamIds.STATUS)
            .clearAndSetSemantics { contentDescription = label }
            .padding(end = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).background(dot, CircleShape))
        Text(status.compactLine(quality), style = MonitorTypography.readout(10.5f, FontWeight.SemiBold),
            color = MonitorPalette.secondary.copy(alpha = .82f), maxLines = 1,
            modifier = Modifier.monitorReadoutShadow())
    }
}

@Composable
private fun Bubble(modifier: Modifier, content: @Composable () -> Unit) {
    Column(modifier.fillMaxWidth().background(MonitorPalette.background.copy(alpha = 0.82f), RoundedCornerShape(12.dp))
        .border(1.dp, MonitorPalette.border, RoundedCornerShape(12.dp)).padding(horizontal = 12.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
}

/**
 * The Live pill for the app root (contract "Live pill"): while a stream runs and no monitor shows
 * its Go live control, the phase with a dot (red live, amber otherwise) and Stop, which asks the
 * same stop confirmation. Draws nothing when no stream runs.
 */
@Composable
fun LiveStreamRootPill(state: LiveStreamState, actions: LiveStreamActions, modifier: Modifier = Modifier) {
    val pill = liveStreamPillState(state) ?: return
    var confirmingStop by remember { mutableStateOf(false) }
    val live = pill.phase == LiveStreamPhase.Live
    val dot = if (live) MonitorPalette.recording else warningColor
    Row(
        modifier
            .background(MonitorPalette.background.copy(alpha = 0.86f), CircleShape)
            .border(1.dp, if (live) MonitorPalette.recording else MonitorPalette.border, CircleShape)
            .padding(start = 12.dp, end = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier.testTag(LiveStreamIds.PILL)
                .clearAndSetSemantics { contentDescription = LiveStreamCopy.pillLabel(pill) },
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(8.dp).background(dot, CircleShape))
            Text(LiveStreamCopy.pillTitle(pill), style = MonitorTypography.readout(12f, FontWeight.SemiBold),
                color = if (live) MonitorPalette.recording else MonitorPalette.text)
        }
        MonitorSettingsActionPill(LiveStreamCopy.STOP, tint = MonitorPalette.recording,
            background = MonitorPalette.recording.copy(alpha = 0.16f),
            modifier = Modifier.testTag(LiveStreamIds.PILL_STOP)
                .semantics { contentDescription = LiveStreamCopy.pillStopLabel(pill.serviceName) }) { confirmingStop = true }
    }
    if (confirmingStop) {
        AlertDialog(onDismissRequest = { confirmingStop = false },
            title = { Text(LiveStreamCopy.STOP_TITLE) },
            text = { Text(LiveStreamCopy.STOP_MESSAGE) },
            confirmButton = {
                TextButton(onClick = { confirmingStop = false; actions.stop() }) {
                    Text(LiveStreamCopy.END_STREAM, color = MonitorPalette.recording)
                }
            },
            dismissButton = { TextButton(onClick = { confirmingStop = false }) { Text(LiveStreamCopy.KEEP_STREAMING) } })
    }
}
