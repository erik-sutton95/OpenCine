package com.opencapture.opencine.appkit

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.max
import androidx.compose.ui.unit.min
import com.opencapture.monitorui.MonitorDrawerTabs
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorInspector
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.MultiviewSafeArea
import com.opencapture.monitorui.monitorChromeClickable
import com.opencapture.monitorui.monitorScrollFade
import com.opencapture.opencine.core.MultiviewMemberLink
import java.util.UUID

private val NoteAmber = Color(0.914f, 0.674f, 0.208f)

/**
 * The Multiview camera settings popup: Live View's trailing side panel with a tab per connected
 * camera on top, the selected camera's live preview and controls, and the category rail on the
 * right. One editor at a time; changing tabs retires the last one before the next camera's opens.
 * The preview and the controls are the app's ([MultiviewScreenHost]); the categories, their lock
 * while recording and the notes are shared. Swift twin: `MultiviewCameraSettingsPanel`.
 */
@Composable
public fun <Camera, Link : MultiviewMemberLink<Camera>> MultiviewCameraSettingsPanel(
    coordinator: MultiviewCoordinator<Camera, Link>,
    host: MultiviewScreenHost,
    initialSlot: Int,
    width: Float,
    height: Float,
    safe: MultiviewSafeArea,
    onDismiss: () -> Unit,
) {
    val members = coordinator.members
    val cameras = members.indices.filter { members[it].camera != null }
    var selectedId by remember { mutableStateOf<UUID?>(null) }
    var category by remember { mutableStateOf(MultiviewSettingsCategory.ISO) }

    fun select(slot: Int) {
        selectedId = members[slot].id
        category = MultiviewSettingsCategory.ISO
        host.openCameraSettings(slot)
    }

    val selected = cameras.firstOrNull { members[it].id == selectedId }
    LaunchedEffect(Unit) { select(initialSlot) }
    DisposableEffect(Unit) { onDispose { coordinator.closeEditors() } }
    // A removed camera's tab goes: the next camera's opens, or the popup closes with the last one.
    val ids = cameras.map { members[it].id }
    LaunchedEffect(ids) {
        if (selectedId != null && ids.none { it == selectedId }) {
            val next = cameras.firstOrNull()
            if (next != null) select(next) else onDismiss()
        }
    }
    // The selected camera's editor opens again once the camera becomes ready.
    val ready = selected?.let { coordinator.controlsAvailable(it) }
    LaunchedEffect(ready) {
        val slot = cameras.firstOrNull { members[it].id == selectedId }
        if (ready == true && slot != null && host.cameraSettings(slot) == null) select(slot)
    }

    // Live View's gimbal side panel container: trailing edge, width, glass, reveal and tap-outside dismissal.
    MonitorInspector(
        title = MultiviewCopy.CAMERA_SETTINGS,
        viewportWidth = width,
        viewportHeight = height,
        onDismiss = onDismiss,
        modifier = Modifier.testTag("multiview.cameraSettings"),
        trailing = true,
        hasNavigation = false,
        safeLeading = safe.leading,
        safeTrailing = safe.trailing,
        safeTop = safe.top,
        safeBottom = safe.bottom,
        close = {
            // Inset from the panel corner; the 48dp target overflows the one-line header.
            Box(Modifier.padding(end = 8.dp).height(20.dp).wrapContentHeight(unbounded = true)) {
                Box(
                    Modifier.size(48.dp).monitorChromeClickable(onClick = onDismiss)
                        .semantics {
                            contentDescription = "Close camera settings"
                            role = Role.Button
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    MonitorIcon(MonitorIcon.X, null, Modifier.size(13.dp), MonitorPalette.muted)
                }
            }
        },
        // Recording stays on Record all and each tile's options; camera tabs sit under the header.
        compactHeader = true,
    ) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val cameraTabScroll = rememberScrollState()
            Row(
                Modifier.fillMaxWidth().monitorScrollFade(cameraTabScroll, vertical = false)
                    .horizontalScroll(cameraTabScroll),
            ) {
                MonitorDrawerTabs(
                    // The tabs read upper-cased, as on iOS.
                    tabs = cameras.map { "${MultiviewTile.letter(it)} · ${coordinator.cameraName(it) ?: "Camera"}".uppercase() },
                    selected = cameras.indexOf(selected).coerceAtLeast(0),
                    onSelect = { index -> if (selectedId != members[cameras[index]].id) select(cameras[index]) },
                )
            }
            val state = selected?.let { host.cameraSettings(it) }
            if (selected != null && state != null) {
                val available = coordinator.controlsAvailable(selected)
                val categories = state.categories
                val sheet = category.takeIf { it in categories } ?: MultiviewSettingsCategory.ISO
                val locked = sheet.locked(state.recording)
                Row(Modifier.weight(1f).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    BoxWithConstraints(Modifier.weight(1f).fillMaxHeight()) {
                        val viewport = maxHeight
                        val density = LocalDensity.current
                        // Tallest controls seen this session, so the preview never makes a category scroll.
                        var controlsReserve by remember { mutableStateOf(200.dp) }
                        val previewHeight = max(72.dp, min(maxWidth * 9f / 16f, maxHeight - controlsReserve - 8.dp))
                        val controlsScroll = rememberScrollState()
                        // Like the assist inspector: the live preview leads the scrolled controls.
                        Column(
                            Modifier.fillMaxSize().monitorScrollFade(controlsScroll).verticalScroll(controlsScroll),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            // 16:9 from the measured column: full width when the tallest controls still fit.
                            key(selected) {
                                val name = coordinator.cameraName(selected) ?: "Camera"
                                host.SettingsPreview(
                                    selected,
                                    Modifier.align(Alignment.CenterHorizontally)
                                        .width(previewHeight * 16f / 9f).height(previewHeight)
                                        .semantics { contentDescription = "$name preview" },
                                )
                            }
                            Column(
                                Modifier.onSizeChanged {
                                    controlsReserve = max(controlsReserve, with(density) { it.height.toDp() })
                                },
                                verticalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                host.SettingsControls(selected, sheet, locked = !available || locked, viewport.value, onDismiss)
                                // Compact status lines; they take space only while present.
                                if (!available) {
                                    Text(MultiviewCopy.CONTROLS_UNAVAILABLE, color = MonitorPalette.muted, style = MonitorTypography.text(11f))
                                } else if (locked) {
                                    Text(MultiviewCopy.LOCKED_WHILE_RECORDING, color = MonitorPalette.muted, style = MonitorTypography.text(11f))
                                }
                                state.note?.let {
                                    Text(it, color = NoteAmber, style = MonitorTypography.text(11f), maxLines = 2)
                                }
                            }
                        }
                    }
                    BoxWithConstraints(Modifier.fillMaxHeight()) {
                        val railHeight = maxHeight
                        val categoryScroll = rememberScrollState()
                        Box(Modifier.monitorScrollFade(categoryScroll).verticalScroll(categoryScroll)) {
                            // The rail's single baseline spans the full content height; tabs stay top-aligned.
                            MonitorDrawerTabs(
                                categories.map { it.title.uppercase() }, categories.indexOf(sheet),
                                onSelect = { category = categories[it] }, vertical = true,
                                modifier = Modifier.heightIn(min = railHeight),
                            )
                        }
                    }
                }
            } else {
                Text(
                    if (selected?.let { members[it].recovering } == true) MultiviewCopy.RECONNECT_BEFORE_SETTINGS
                    else MultiviewCopy.WAITING_FOR_CONTROLS,
                    color = MonitorPalette.muted, style = MonitorTypography.text(13f),
                    modifier = Modifier.padding(vertical = 16.dp),
                )
            }
        }
    }
}
