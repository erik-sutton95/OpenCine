package com.opencapture.monitorui.settings

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import com.opencapture.monitorui.LocalMonitorInspectorHelp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography

private val ChromeShape = RoundedCornerShape(12.dp)
private fun chromeStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    if (mono) MonitorTypography.readout(size, weight) else MonitorTypography.text(size, weight)
private fun Modifier.settingsCardSurface(): Modifier =
    background(MonitorPalette.surface, ChromeShape).border(1.dp, MonitorPalette.border, ChromeShape)

@Composable
private fun Modifier.settingsClickable(role: Role, onClick: () -> Unit): Modifier = clickable(
    interactionSource = remember { MutableInteractionSource() }, indication = null,
    role = role, onClick = onClick,
)

@Composable
fun MonitorSettingsRowCard(
    title: String? = null,
    onReset: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .settingsCardSurface()
            .padding(horizontal = 13.dp)
            .padding(top = if (title != null) 0.dp else 8.dp, bottom = 4.dp),
        verticalArrangement = Arrangement.spacedBy(com.opencapture.monitorui.MonitorLayoutPolicy.SETTINGS_TITLE_CONTENT_GAP.dp),
    ) {
        if (title != null) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(top = 11.dp)
                    .heightIn(min = com.opencapture.monitorui.MonitorLayoutPolicy.SETTINGS_TITLE_MIN_HEIGHT.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(title, style = chromeStyle(13f, FontWeight.SemiBold), color = MonitorPalette.text)
                Spacer(Modifier.weight(1f))
                if (onReset != null) MonitorSettingsResetButton(onClick = onReset)
            }
        }
        content()
    }
}

@Composable
fun MonitorSettingsResetButton(onClick: () -> Unit) {
    val description = "Reset to defaults"
    Box(
        Modifier.size(28.dp)
            .background(MonitorPalette.background.copy(alpha = 0.42f), CircleShape)
            .border(1.dp, MonitorPalette.border, CircleShape)
            .settingsClickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(MonitorIcon.REFRESH_CW, null, Modifier.size(12.dp), MonitorPalette.muted)
    }
}

@Composable
fun MonitorSettingsInlineRow(
    title: String,
    help: String? = null,
    showTopDivider: Boolean = true,
    stacked: Boolean = false,
    trailing: @Composable () -> Unit,
) = SettingsInlineRowLayout(title, help, showTopDivider, stacked, Modifier, trailing)

/** [rowModifier] lands on the label-and-control line, never on the divider or inspector help. */
@Composable
private fun SettingsInlineRowLayout(
    title: String,
    help: String?,
    showTopDivider: Boolean,
    stacked: Boolean,
    rowModifier: Modifier,
    trailing: @Composable () -> Unit,
) {
    val inspectorHelp = LocalMonitorInspectorHelp.current
    val label = @Composable {
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                title,
                style = chromeStyle(12.5f, FontWeight.SemiBold),
                color = MonitorPalette.text,
                maxLines = if (stacked) 2 else 1,
            )
            if (inspectorHelp == null) help?.let { MonitorSettingsHelpBadge(it) }
        }
    }
    Column {
        if (showTopDivider) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(MonitorPalette.border))
        }
        if (stacked) {
            Column(
                Modifier.fillMaxWidth().then(rowModifier).defaultMinSize(minHeight = 44.dp).padding(vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                label()
                Box(Modifier.fillMaxWidth()) { trailing() }
            }
        } else {
            Row(
                Modifier.fillMaxWidth().then(rowModifier).defaultMinSize(minHeight = 50.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                label()
                Box(
                    Modifier.weight(1f).padding(start = 4.dp),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    trailing()
                }
            }
        }
        if (inspectorHelp == true && !help.isNullOrEmpty()) {
            Text(
                help,
                modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
                style = chromeStyle(10f, FontWeight.Normal),
                color = MonitorPalette.muted,
            )
        }
    }
}

@Composable
fun MonitorSettingsSwitchInlineRow(
    title: String,
    isOn: Boolean,
    help: String? = null,
    showTopDivider: Boolean = true,
    stacked: Boolean = false,
    testTag: String? = null,
    onToggle: () -> Unit,
) {
    // The whole line is one switch for TalkBack and UI Automator: its merged title text, its On
    // or Off state and a single activation (hardware pass 7.3). No separate semantics block: an
    // extra block here becomes its own node that names the switch without its state, which is
    // what a reader found first before this fix. The help badge keeps its own node.
    val access =
        Modifier.toggleable(
            value = isOn,
            interactionSource = remember { MutableInteractionSource() },
            indication = null,
            role = Role.Switch,
            onValueChange = { onToggle() },
        ).then(if (testTag != null) Modifier.testTag(testTag) else Modifier)
    SettingsInlineRowLayout(title, help, showTopDivider, stacked, access) {
        MonitorSettingsSwitchGraphic(isOn = isOn)
    }
}

@Composable
fun MonitorSettingsHelpBadge(text: String) {
    var open by remember { mutableStateOf(false) }
    val description = "Help"
    Box {
        // A 16dp mark inside a 24dp target. The full 44dp floor would reserve 44dp of ROW
        // width on every helped row and squeeze the trailing control off a landscape-phone
        // pane; this compact help target preserves space for the setting label and control.
        Box(
            Modifier.size(24.dp)
                .settingsClickable(role = Role.Button) { open = !open }
                .semantics { contentDescription = description },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size(16.dp)
                    .background(MonitorPalette.background.copy(alpha = 0.5f), CircleShape)
                    .border(1.dp, MonitorPalette.border, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                MonitorIcon(MonitorIcon.INFO, null, Modifier.size(9.dp), MonitorPalette.faint)
            }
        }
        if (open) {
            Popup(onDismissRequest = { open = false }) {
                Box(
                    Modifier
                        .width(248.dp)
                        .background(MonitorPalette.surface, ChromeShape)
                        .border(1.dp, MonitorPalette.border, ChromeShape)
                        .padding(12.dp),
                ) {
                    Text(
                        text,
                        style = chromeStyle(12f, FontWeight.Normal),
                        color = MonitorPalette.text,
                    )
                }
            }
        }
    }
}

@Composable
fun MonitorSettingsSwitchGraphic(isOn: Boolean) {
    val thumbX by animateFloatAsState(if (isOn) 20.5f else 3.5f, tween(160), label = "settings-switch")
    Box(
        Modifier
            .size(39.dp, 22.dp)
            .background(if (isOn) MonitorPalette.accent.copy(alpha = .16f) else MonitorPalette.surface, CircleShape)
            .border(1.dp, if (isOn) MonitorPalette.accent.copy(alpha = .16f) else MonitorPalette.border, CircleShape),
    ) {
        Box(
            Modifier
                .offset(x = thumbX.dp, y = 3.5.dp)
                .size(15.dp)
                .background(if (isOn) MonitorPalette.accent else MonitorPalette.muted, CircleShape),
        )
    }
}

@Composable
fun MonitorSettingsValueText(value: String) {
    Text(
        value,
        style = chromeStyle(12.5f, FontWeight.Medium, mono = true),
        color = MonitorPalette.muted,
        maxLines = 1,
    )
}
