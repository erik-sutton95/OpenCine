package com.opencapture.monitorui.settings

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.MonitorIcon
private val ChromeShape = androidx.compose.foundation.shape.RoundedCornerShape(12.dp)
private fun chromeStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    if (mono) MonitorTypography.readout(size, weight) else MonitorTypography.text(size, weight)
private fun Modifier.settingsCardSurface(): Modifier =
    background(MonitorPalette.surface, ChromeShape).border(1.dp, MonitorPalette.border, ChromeShape)
@Composable
private fun Modifier.settingsClickable(role: Role, enabled: Boolean = true, onClick: () -> Unit): Modifier =
    clickable(interactionSource = remember { MutableInteractionSource() }, indication = null,
        enabled = enabled, role = role, onClick = onClick)

@Composable
public fun MonitorSettingsTextAction(title: String, color: Color = MonitorPalette.accent, onClick: () -> Unit) {
    Text(title, style = MonitorTypography.text(13f, FontWeight.SemiBold), color = color,
        modifier = Modifier.settingsClickable(role = Role.Button, onClick = onClick))
}

@Composable
public fun MonitorSettingsActionPill(
    title: String,
    icon: MonitorIcon? = null,
    tint: Color = MonitorPalette.accent,
    background: Color = MonitorPalette.accent.copy(alpha = 0.16f),
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    minimumTouchTarget: Boolean = true,
    onClick: () -> Unit,
) {
    Row(
        modifier
            // 48 dp touch target around the unchanged capsule; inline rows are 50 dp tall. A host
            // that keeps the capsule's own bounds as its touch area passes minimumTouchTarget false.
            .settingsClickable(role = Role.Button, enabled = enabled, onClick = onClick)
            .then(if (minimumTouchTarget) Modifier.minimumInteractiveComponentSize() else Modifier)
            .alpha(if (enabled) 1f else 0.45f)
            .background(background, CircleShape)
            .border(1.dp, tint.copy(alpha = 0.5f), CircleShape)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.let {
            MonitorIcon(icon = it, contentDescription = null, tint = tint, modifier = Modifier.size(13.dp))
        }
        Text(
            title.uppercase(),
            style = chromeStyle(10.5f, FontWeight.Bold, mono = true),
            color = tint,
            maxLines = 1,
            letterSpacing = 0.6.sp,
        )
    }
}

/** The typed digits clamped to `0...maximum`; null when there is no number to commit. */
internal fun monitorSettingsNumberEntry(raw: String, maximum: Int): Int? = raw.toIntOrNull()?.coerceIn(0, maximum)

@OptIn(ExperimentalFoundationApi::class)
@Composable
public fun MonitorSettingsNumberField(
    value: Int,
    maximum: Int,
    onChange: (Int) -> Unit,
) {
    var editing by remember { mutableStateOf(false) }
    var editorHadFocus by remember { mutableStateOf(false) }
    var draft by remember(value) { mutableStateOf(value.toString()) }
    val focusRequester = remember { FocusRequester() }
    val bringIntoView = remember { BringIntoViewRequester() }
    val keyboard = LocalSoftwareKeyboardController.current
    fun commit() {
        monitorSettingsNumberEntry(draft, maximum)?.let(onChange)
        editing = false
        editorHadFocus = false
        keyboard?.hide()
    }
    Box(
        Modifier
            .height(30.dp)
            .width(44.dp)
            .background(MonitorPalette.background.copy(alpha = 0.5f), ChromeShape)
            .border(1.dp, MonitorPalette.border, ChromeShape)
            .bringIntoViewRequester(bringIntoView)
            .then(
                if (editing) {
                    Modifier
                } else {
                    Modifier.settingsClickable(role = Role.Button) {
                        editorHadFocus = false
                        editing = true
                    }
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (editing) {
            LaunchedEffect(Unit) {
                focusRequester.requestFocus()
                bringIntoView.bringIntoView()
            }
            BasicTextField(
                value = draft,
                onValueChange = { next -> draft = next.filter(Char::isDigit).take(3) },
                textStyle =
                    chromeStyle(12f, FontWeight.SemiBold, mono = true)
                        .copy(color = MonitorPalette.text, textAlign = TextAlign.Center),
                keyboardOptions =
                    KeyboardOptions(
                        keyboardType = KeyboardType.Number,
                        imeAction = ImeAction.Done,
                    ),
                keyboardActions = KeyboardActions(onDone = { commit() }),
                singleLine = true,
                cursorBrush = SolidColor(MonitorPalette.accent),
                modifier =
                    Modifier
                        .widthIn(min = 28.dp, max = 40.dp)
                        .focusRequester(focusRequester)
                        .onFocusChanged {
                            // A new editor starts unfocused before requestFocus runs.
                            // Commit only after an acquired focus is actually lost.
                            if (it.isFocused) editorHadFocus = true
                            else if (editing && editorHadFocus) commit()
                        },
            )
        } else {
            Text(
                value.toString(),
                style = chromeStyle(12f, FontWeight.SemiBold, mono = true),
                color = MonitorPalette.text,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
public fun MonitorSettingsGroupCard(
    title: String,
    caption: String,
    onReset: (() -> Unit)? = null,
    captionMaxLines: Int = 2,
    /**
     * When non-null the card collapses to its header and the whole header toggles it. Long tabs
     * (Display carries three DISP sections) read as a short list of sections this way instead of
     * one unbroken scroll of controls.
     */
    expanded: Boolean? = null,
    onExpandToggle: (() -> Unit)? = null,
    content: @Composable () -> Unit,
) {
    val isExpanded = expanded ?: true
    Column(
        Modifier.fillMaxWidth().settingsCardSurface().padding(horizontal = 13.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(
            Modifier.then(
                if (expanded != null && onExpandToggle != null) {
                    Modifier.settingsClickable(role = Role.Button, onClick = onExpandToggle)
                } else {
                    Modifier
                }
            ),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    title,
                    style = chromeStyle(13f, FontWeight.SemiBold),
                    color = MonitorPalette.text,
                )
                Spacer(Modifier.weight(1f))
                if (onReset != null && isExpanded) {
                    MonitorSettingsResetButton(onClick = onReset)
                }
                if (expanded != null) {
                    MonitorIcon(
                        icon = if (isExpanded) MonitorIcon.CHEVRON_UP else MonitorIcon.CHEVRON_DOWN,
                        contentDescription = null,
                        tint = MonitorPalette.muted,
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            Text(
                caption,
                style = chromeStyle(11.5f, FontWeight.Normal),
                color = MonitorPalette.muted,
                maxLines = captionMaxLines,
            )
        }
        if (isExpanded) {
            content()
        }
    }
}

@Composable
public fun MonitorSettingsDisplayToggle(
    title: String,
    isOn: Boolean,
    modifier: Modifier = Modifier,
    onToggle: () -> Unit,
) {
    Row(
        modifier
            .height(46.dp)
            .background(MonitorPalette.background.copy(alpha = 0.38f), ChromeShape)
            .border(1.dp, MonitorPalette.border, ChromeShape)
            .settingsClickable(role = Role.Switch, onClick = onToggle)
            .padding(horizontal = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            title,
            style = chromeStyle(11.5f, FontWeight.SemiBold),
            color = MonitorPalette.text,
            maxLines = 1,
        )
        Spacer(Modifier.weight(1f))
        MonitorSettingsSwitchGraphic(isOn = isOn)
    }
}
