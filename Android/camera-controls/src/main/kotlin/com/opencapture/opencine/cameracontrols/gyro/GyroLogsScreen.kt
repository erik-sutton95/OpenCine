package com.opencapture.opencine.cameracontrols.gyro

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.dismiss
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorLinkHealth
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.gyro.GyroLogEntry
import com.opencapture.opencine.gyro.GyroTakeStatus
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlinx.coroutines.launch

/** What the gyro logs screen and the take page can ask of the host. */
public class GyroLogsActions(
    /** Share the finished logs with these ids, newest first; the host opens its share sheet. */
    public val share: (List<String>) -> Unit = {},
    /** Delete one finished take and its files. */
    public val delete: (GyroLogEntry) -> Unit = {},
    /** Hide the tip card for good. */
    public val dismissTip: () -> Unit = {},
    /** Turn Gyro on from the empty state. */
    public val turnOnGyro: () -> Unit = {},
    /** Leave the logs screen. */
    public val close: () -> Unit = {},
)

/**
 * The gyro logs: takes grouped by day with one status badge each, a dismissible tip, an empty state
 * and a Select mode that shares several takes at once. Portrait taps a take to open its page with a
 * back affordance; landscape keeps the list on the left (40 percent) and the selected take on the
 * right (60 percent), the first take selected by default.
 *
 * The screen owns only presentation states (selected take, selection, pending delete); sharing,
 * deleting, dismissing the tip, turning Gyro on and closing are the host's [actions].
 */
@Composable
public fun GyroLogsScreen(
    entries: List<GyroLogEntry>,
    tipVisible: Boolean,
    gyroEnabled: Boolean,
    nowMillis: Long,
    actions: GyroLogsActions,
    modifier: Modifier = Modifier,
) {
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    var selecting by rememberSaveable { mutableStateOf(false) }
    var selection by remember { mutableStateOf(emptySet<String>()) }
    var pendingDelete by remember { mutableStateOf<GyroLogEntry?>(null) }

    val locale = LocalConfiguration.current.locales[0]
    val sections = groupGyroLogs(entries, nowMillis, ZoneId.systemDefault(), locale)
    val selected = entries.firstOrNull { it.id == selectedId }
    val chosen = entries.filter { it.canShare && it.id in selection }

    fun toggle(entry: GyroLogEntry) {
        selection = if (entry.id in selection) selection - entry.id else selection + entry.id
    }

    fun cancelSelection() {
        selecting = false
        selection = emptySet()
    }

    fun shareSelection() {
        if (chosen.isNotEmpty()) actions.share(chosen.map { it.id })
        cancelSelection()
    }

    // Back in Select mode leaves the mode, not the screen.
    BackHandler(enabled = selecting) { cancelSelection() }

    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(MonitorPalette.background)
            .semantics { testTagsAsResourceId = true },
    ) {
        val landscape = maxWidth > maxHeight
        val canSelect = entries.any { it.canShare }
        if (landscape && entries.isNotEmpty()) {
            Column(Modifier.fillMaxSize().systemBarsPadding()) {
                Row(Modifier.fillMaxSize()) {
                    Column(Modifier.weight(0.4f).fillMaxHeight()) {
                        LogsTopBar(
                            canSelect = canSelect,
                            selecting = selecting,
                            onSelect = { selecting = true },
                            onCancelSelect = ::cancelSelection,
                            onClose = actions.close,
                        )
                        if (tipVisible) LogsTip(onDismiss = actions.dismissTip)
                        LogsList(
                            sections = sections,
                            selecting = selecting,
                            selection = selection,
                            onOpen = { selectedId = it.id },
                            onToggle = ::toggle,
                            onRequestDelete = { pendingDelete = it },
                            modifier = Modifier.weight(1f),
                        )
                        if (selecting) {
                            LogsShareBar(count = chosen.size, onShare = ::shareSelection)
                        }
                    }
                    Box(Modifier.width(1.dp).fillMaxHeight().background(MonitorPalette.border))
                    Box(Modifier.weight(0.6f).fillMaxHeight()) {
                        val take = selected ?: sections.first().entries.first()
                        GyroTakeBody(
                            entry = take,
                            onShare = { actions.share(listOf(take.id)) },
                            showShare = !selecting,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
        } else if (selected != null) {
            BackHandler { selectedId = null }
            Column(Modifier.fillMaxSize().systemBarsPadding()) {
                LogsBackBar(onBack = { selectedId = null })
                GyroTakeBody(
                    entry = selected,
                    onShare = { actions.share(listOf(selected.id)) },
                    showShare = true,
                    modifier = Modifier.fillMaxSize(),
                )
            }
        } else {
            Column(Modifier.fillMaxSize().systemBarsPadding()) {
                LogsTopBar(
                    canSelect = canSelect,
                    selecting = selecting,
                    onSelect = { selecting = true },
                    onCancelSelect = ::cancelSelection,
                    onClose = actions.close,
                )
                if (entries.isEmpty()) {
                    Box(
                        Modifier.weight(1f).fillMaxWidth(),
                        contentAlignment = Alignment.Center,
                    ) {
                        LogsEmptyState(gyroEnabled = gyroEnabled, onTurnOnGyro = actions.turnOnGyro)
                    }
                } else {
                    Column(Modifier.weight(1f).fillMaxWidth()) {
                        if (tipVisible) LogsTip(onDismiss = actions.dismissTip)
                        LogsList(
                            sections = sections,
                            selecting = selecting,
                            selection = selection,
                            onOpen = { selectedId = it.id },
                            onToggle = ::toggle,
                            onRequestDelete = { pendingDelete = it },
                            modifier = Modifier.fillMaxWidth().weight(1f),
                        )
                    }
                    if (selecting) {
                        LogsShareBar(count = chosen.size, onShare = ::shareSelection)
                    }
                }
            }
        }
        pendingDelete?.let { entry ->
            DeleteConfirmation(
                onDelete = {
                    pendingDelete = null
                    actions.delete(entry)
                },
                onDismiss = { pendingDelete = null },
            )
        }
    }
}

/** The title bar of the list: title, Select or Cancel, and the close action. */
@Composable
private fun LogsTopBar(
    canSelect: Boolean,
    selecting: Boolean,
    onSelect: () -> Unit,
    onCancelSelect: () -> Unit,
    onClose: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = GyroCopy.logsTitle,
            modifier = Modifier.weight(1f).semantics { heading() },
            color = MonitorPalette.text,
            style = MonitorTypography.text(20f, FontWeight.SemiBold),
        )
        if (selecting) {
            GyroLinkButton(
                text = GyroCopy.cancel,
                onClick = onCancelSelect,
                fillWidth = false,
                tag = "gyro.select.cancel",
            )
        } else if (canSelect) {
            GyroLinkButton(
                text = GyroCopy.select,
                onClick = onSelect,
                fillWidth = false,
                tag = "gyro.select",
            )
        }
        GyroLinkButton(
            text = GyroCopy.done,
            onClick = onClose,
            fillWidth = false,
            tag = "gyro.close",
        )
    }
}

/** The take page's back affordance: a chevron and the screen's own title, in the accent. */
@Composable
private fun LogsBackBar(onBack: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClick = onBack)
                .semantics(mergeDescendants = true) { role = Role.Button }
                .testTag("gyro.back")
                .padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            MonitorIcon(
                icon = MonitorIcon.CHEVRON_LEFT,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
                tint = MonitorPalette.accent,
            )
            Text(
                text = GyroCopy.logsTitle,
                color = MonitorPalette.accent,
                style = MonitorTypography.text(16f, FontWeight.Medium),
            )
        }
    }
}

/** One dismissible tip line above the sections, in the mockup's outlined card. */
@Composable
private fun LogsTip(onDismiss: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 10.dp, vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .border(1.dp, MonitorPalette.border, RoundedCornerShape(12.dp))
            .testTag("gyro.tip")
            .padding(start = 12.dp, top = 10.dp, bottom = 10.dp, end = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        MonitorIcon(
            icon = MonitorIcon.INFO,
            contentDescription = null,
            modifier = Modifier.size(16.dp),
            tint = GyroPalette.overline,
        )
        Text(
            text = GyroCopy.tip,
            modifier = Modifier.weight(1f),
            color = GyroPalette.body,
            style = MonitorTypography.text(12f),
        )
        Box(
            Modifier
                .size(32.dp)
                .clickable(role = Role.Button, onClick = onDismiss)
                .semantics(mergeDescendants = true) {
                    contentDescription = GyroCopy.dismissTip
                    role = Role.Button
                }
                .testTag("gyro.tip.dismiss"),
            contentAlignment = Alignment.Center,
        ) {
            MonitorIcon(
                icon = MonitorIcon.X,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = GyroPalette.overline,
            )
        }
    }
}

/** The day sections and their take rows, newest first. */
@Composable
private fun LogsList(
    sections: List<GyroLogSection>,
    selecting: Boolean,
    selection: Set<String>,
    onOpen: (GyroLogEntry) -> Unit,
    onToggle: (GyroLogEntry) -> Unit,
    onRequestDelete: (GyroLogEntry) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 10.dp),
    ) {
        for (section in sections) {
            GyroOverline(
                text = section.title,
                textAlign = TextAlign.Start,
                modifier = Modifier.padding(top = 10.dp, bottom = 4.dp),
            )
            for (entry in section.entries) {
                key(entry.id) {
                    SwipeableLogRow(
                        entry = entry,
                        selecting = selecting,
                        selected = entry.id in selection,
                        onOpen = { onOpen(entry) },
                        onToggle = { onToggle(entry) },
                        onRequestDelete = { onRequestDelete(entry) },
                    )
                    Spacer(Modifier.height(6.dp))
                }
            }
        }
        Spacer(Modifier.height(4.dp))
    }
}

/** One take row: glyph, time and camera with length, and the status badge at the trailing edge. */
@Composable
private fun SwipeableLogRow(
    entry: GyroLogEntry,
    selecting: Boolean,
    selected: Boolean,
    onOpen: () -> Unit,
    onToggle: () -> Unit,
    onRequestDelete: () -> Unit,
) {
    val state = rememberSwipeToDismissBoxState()
    val scope = rememberCoroutineScope()
    SwipeToDismissBox(
        state = state,
        backgroundContent = { DeleteBackground() },
        modifier = Modifier.fillMaxWidth(),
        enableDismissFromStartToEnd = false,
        enableDismissFromEndToStart = !entry.active,
        gesturesEnabled = !entry.active,
        onDismiss = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                onRequestDelete()
                scope.launch { state.reset() }
            }
        },
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(12.dp))
                .background(MonitorPalette.surface)
                .padding(horizontal = 10.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            val selectable = selecting && entry.canShare
            Row(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(8.dp))
                    .then(
                        when {
                            selectable -> Modifier.toggleable(
                                value = selected,
                                role = Role.Checkbox,
                                onValueChange = { onToggle() },
                            )
                            // A row that cannot take part in the selection has no action at all.
                            selecting -> Modifier
                            else -> Modifier.clickable(role = Role.Button, onClick = onOpen)
                        },
                    )
                    .semantics(mergeDescendants = true) {
                        contentDescription = rowDescription(entry)
                        if (!entry.active) {
                            dismiss {
                                onRequestDelete()
                                true
                            }
                        }
                    }
                    .testTag("gyro.row.${entry.id}")
                    .padding(vertical = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(9.dp),
            ) {
                LeadingGlyph(entry = entry, selecting = selecting, selected = selected)
                Column(
                    Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Text(
                        text = logStartTime(entry.startDateMillis),
                        modifier = Modifier.clearAndSetSemantics {},
                        color = MonitorPalette.text,
                        style = MonitorTypography.text(14f, FontWeight.SemiBold),
                    )
                    Text(
                        text = rowSubtitle(entry),
                        modifier = Modifier.clearAndSetSemantics {},
                        color = GyroPalette.body,
                        style = MonitorTypography.text(12f),
                    )
                }
            }
            StatusBadge(entry.status)
        }
    }
}

/** The leading dot, waveform or selection checkmark of one row. */
@Composable
private fun LeadingGlyph(entry: GyroLogEntry, selecting: Boolean, selected: Boolean) {
    when {
        selecting && entry.canShare -> MonitorIcon(
            icon = if (selected) MonitorIcon.CIRCLE_CHECK else MonitorIcon.CIRCLE,
            contentDescription = null,
            modifier = Modifier.size(20.dp),
            tint = if (selected) MonitorPalette.accent else GyroPalette.overline,
        )
        entry.status == GyroTakeStatus.Recording -> Box(
            Modifier.size(20.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(MonitorPalette.recording),
            )
        }
        else -> MonitorIcon(
            icon = MonitorIcon.AUDIO_WAVEFORM,
            contentDescription = null,
            modifier = Modifier.size(20.dp),
            tint = GyroPalette.body,
        )
    }
}

/** One status badge: accent for Ready, amber for a usable warning, red for REC. */
@Composable
private fun StatusBadge(status: GyroTakeStatus) {
    val ink = when (status) {
        GyroTakeStatus.Ready -> MonitorPalette.accent
        GyroTakeStatus.Recording -> MonitorPalette.recording
        else -> MonitorLinkHealth.watch
    }
    Text(
        text = GyroCopy.status(status),
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(ink.copy(alpha = 0.16f))
            .padding(horizontal = 8.dp, vertical = 3.dp)
            // The merged row already reads the status: the badge is not a second TalkBack stop.
            .clearAndSetSemantics { testTag = "gyro.badge" },
        color = ink,
        style = MonitorTypography.text(12f, FontWeight.SemiBold),
        maxLines = 1,
    )
}

/** The red delete surface revealed by an end-to-start swipe. */
@Composable
private fun DeleteBackground() {
    Box(
        Modifier
            .fillMaxSize()
            .clip(RoundedCornerShape(12.dp))
            .background(MonitorPalette.recording),
        contentAlignment = Alignment.CenterEnd,
    ) {
        MonitorIcon(
            icon = MonitorIcon.TRASH,
            contentDescription = null,
            modifier = Modifier.padding(end = 18.dp).size(18.dp),
            tint = MonitorPalette.text,
        )
    }
}

/** The empty logs screen: one glyph, the copy and Turn on Gyro only while Gyro is off. */
@Composable
private fun LogsEmptyState(gyroEnabled: Boolean, onTurnOnGyro: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier
                .size(96.dp)
                .clip(CircleShape)
                .border(1.dp, MonitorPalette.border, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            MonitorIcon(
                icon = MonitorIcon.AUDIO_WAVEFORM,
                contentDescription = null,
                modifier = Modifier.size(40.dp),
                tint = MonitorPalette.accent,
            )
        }
        GyroTitle(text = GyroCopy.emptyTitle, textAlign = TextAlign.Center)
        GyroBody(text = GyroCopy.emptyBody, textAlign = TextAlign.Center)
        if (!gyroEnabled) {
            Spacer(Modifier.height(6.dp))
            GyroPrimaryButton(
                text = GyroCopy.turnOnGyro,
                onClick = onTurnOnGyro,
                tag = "gyro.empty.turnOn",
            )
        }
    }
}

/** The Select mode's only action: the share count, disabled until something is selected. */
@Composable
private fun LogsShareBar(count: Int, onShare: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp)) {
        GyroPrimaryButton(
            text = GyroCopy.shareCount(count),
            onClick = onShare,
            enabled = count > 0,
        )
    }
}

/** The delete confirmation; the take leaves through the host's delete action. */
@Composable
private fun DeleteConfirmation(onDelete: () -> Unit, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Text(
                text = GyroCopy.deleteTitle,
                color = MonitorPalette.text,
                style = MonitorTypography.text(18f, FontWeight.SemiBold),
            )
        },
        confirmButton = {
            TextButton(onClick = onDelete) {
                Text(
                    text = GyroCopy.delete,
                    color = MonitorPalette.recording,
                    style = MonitorTypography.text(16f, FontWeight.SemiBold),
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(
                    text = GyroCopy.cancel,
                    color = MonitorPalette.accent,
                    style = MonitorTypography.text(16f),
                )
            }
        },
        containerColor = MonitorPalette.surface,
    )
}

/** The localized short start time of one take. */
private fun logStartTime(millis: Long): String =
    Instant.ofEpochMilli(millis)
        .atZone(ZoneId.systemDefault())
        .toLocalTime()
        .format(
            DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT)
                .withLocale(Locale.getDefault()),
        )

/** The camera and length line of one row, without the separator when the length is unknown. */
private fun rowSubtitle(entry: GyroLogEntry): String {
    val length = entry.durationSeconds?.let(GyroCopy::length)
    return if (length == null) entry.cameraLabel else entry.cameraLabel + GyroCopy.separator + length
}

/** What TalkBack reads for one row: time, camera, length and status. */
private fun rowDescription(entry: GyroLogEntry): String {
    val parts = mutableListOf(logStartTime(entry.startDateMillis), entry.cameraLabel)
    entry.durationSeconds?.let { parts += GyroCopy.length(it) }
    parts += GyroCopy.status(entry.status)
    return parts.joinToString(", ")
}
