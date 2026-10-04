package com.opencapture.monitorui

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.settings.MonitorSettingsChoices
import com.opencapture.monitorui.settings.MonitorSettingsHelpBadge

private val DeliveryOptionShape = RoundedCornerShape(12.dp)

/** Fixed delivery composition. The host supplies only each destination's artwork. */
@Composable
fun MonitorMediaDeliveryPanel(
    value: MonitorMediaDeliveryValue,
    onAction: (MonitorMediaDeliveryValue.Action) -> Unit,
    modifier: Modifier = Modifier,
    destinationIcon: @Composable (String) -> Unit,
) {
    Column(modifier.heightIn(max = 520.dp)
        .clip(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
        .monitorMaterial(MonitorMaterial.Delivery)
        .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {}
        .padding(16.dp)) {
        DeliveryHeader(value, onAction)
        Spacer(Modifier.height(12.dp))
        val scroll = rememberScrollState()
        Column(Modifier.weight(1f, fill = false).monitorScrollFade(scroll).verticalScroll(scroll)
            .testTag("monitor.share.optionsScroll"), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(value.selectionLabel, style = MonitorTypography.text(12.5f, FontWeight.SemiBold), color = MonitorPalette.text)
                value.notices.forEach { notice ->
                    Text(notice.text, style = MonitorTypography.text(12f),
                        color = if (notice.accented) MonitorPalette.accent else MonitorPalette.muted)
                }
            }
            if (value.step == MonitorMediaDeliveryValue.Step.DESTINATION) {
                DeliverySectionHeader("DESTINATION")
                value.destinations.forEach { destination ->
                    Row(Modifier.fillMaxWidth().deliveryOptionPlate()
                        .monitorChromeClickable(enabled = destination.enabled) {
                            onAction(MonitorMediaDeliveryValue.Action.Destination(destination.id))
                        }.padding(horizontal = 12.dp, vertical = 10.dp)
                        .testTag("monitor.share.destination.${destination.id}"),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) { destinationIcon(destination.id) }
                        Column(Modifier.weight(1f)) {
                            Text(destination.title, style = MonitorTypography.text(11.5f, FontWeight.SemiBold),
                                color = if (destination.enabled) MonitorPalette.text else MonitorPalette.faint)
                            Text(destination.subtitle, style = MonitorTypography.text(11f), color = MonitorPalette.muted)
                        }
                        MonitorIcon(MonitorIcon.CHEVRON_RIGHT, null, Modifier.size(12.dp), MonitorPalette.faint)
                    }
                }
                value.upcoming.forEach { title ->
                    Row(Modifier.fillMaxWidth().deliveryOptionPlate(.2f).padding(horizontal = 12.dp, vertical = 14.dp)
                        .semantics { contentDescription = "$title, Coming soon" }
                        .testTag("monitor.share.upcoming.$title"), verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        MonitorIcon(MonitorIcon.FOLDER, null, Modifier.size(24.dp), MonitorPalette.muted)
                        Text(title, Modifier.weight(1f), style = MonitorTypography.text(14f, FontWeight.SemiBold),
                            color = MonitorPalette.muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text("Coming soon", style = MonitorTypography.text(11f), color = MonitorPalette.muted)
                    }
                }
            } else {
                value.service?.let { DeliveryService(it, onAction) }
                value.export?.let { DeliveryExport(it, onAction) }
            }
            value.status?.let { Text(it, style = MonitorTypography.text(12f), color = MonitorPalette.accent) }
        }
        value.footer?.let { footer ->
            Spacer(Modifier.height(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                footer.summary?.let { Text(it, style = MonitorTypography.readout(9.5f), color = MonitorPalette.muted,
                    modifier = Modifier.testTag("monitor.share.summary")) }
                footer.postExport?.let { DeliveryChoices(it, MonitorMediaDeliveryValue.Selection.POST_EXPORT, onAction) }
                DeliveryActionButton(footer.actionTitle, footer.enabled, Modifier.testTag("monitor.share.begin")) {
                    onAction(MonitorMediaDeliveryValue.Action.Begin)
                }
            }
        }
    }
}

@Composable private fun DeliveryHeader(value: MonitorMediaDeliveryValue, action: (MonitorMediaDeliveryValue.Action) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (value.step == MonitorMediaDeliveryValue.Step.DESTINATION) {
            MonitorIcon(MonitorIcon.SHARE, null, Modifier.size(13.dp), MonitorPalette.text)
            Text("SHARE", style = MonitorTypography.text(9f, FontWeight.SemiBold), color = MonitorPalette.text)
            Spacer(Modifier.weight(1f))
        } else {
            Row(Modifier.monitorChromeClickable { action(MonitorMediaDeliveryValue.Action.Back) }.testTag("monitor.share.back"),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                MonitorIcon(MonitorIcon.CHEVRON_LEFT, null, Modifier.size(12.dp), MonitorPalette.accent)
                Text("Back", style = MonitorTypography.text(12.5f, FontWeight.SemiBold), color = MonitorPalette.accent)
            }
            Column(Modifier.weight(1f)) {
                Text(value.title, style = MonitorTypography.text(12.5f, FontWeight.SemiBold), color = MonitorPalette.text)
                Text("Options", style = MonitorTypography.text(11f), color = MonitorPalette.muted)
            }
        }
        Box(Modifier.size(30.dp).clip(CircleShape).monitorMaterial(MonitorMaterial.Delivery, CircleShape)
            .monitorChromeClickable { action(MonitorMediaDeliveryValue.Action.Close) }
            .semantics { contentDescription = "Close" }.testTag("monitor.share.close"), contentAlignment = Alignment.Center) {
            MonitorIcon(MonitorIcon.X, null, Modifier.size(11.4.dp), MonitorPalette.text)
        }
    }
}

@Composable private fun DeliveryService(service: MonitorMediaDeliveryValue.Service, action: (MonitorMediaDeliveryValue.Action) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        when (service) {
            is MonitorMediaDeliveryValue.Service.InternetGate -> {
                DeliverySectionHeader(service.heading)
                Text(service.message, style = MonitorTypography.text(13f), color = MonitorPalette.muted)
                if (service.busy) DeliveryBusy(service.busyTitle)
                else DeliveryActionButton("Hop to internet", true) { action(MonitorMediaDeliveryValue.Action.HopToInternet) }
            }
            is MonitorMediaDeliveryValue.Service.Projects -> {
                DeliverySectionHeader(service.heading)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Project", style = MonitorTypography.text(14f, FontWeight.SemiBold), color = MonitorPalette.text)
                    MonitorSettingsHelpBadge(service.help)
                }
                service.signInNotice?.let { Text(it, style = MonitorTypography.text(12f), color = MonitorPalette.muted) }
                when {
                    service.loading -> DeliveryBusy("Loading projects…")
                    service.error != null -> {
                        Text(service.error, style = MonitorTypography.text(12f), color = MonitorPalette.accent)
                        Text("Retry", style = MonitorTypography.text(13f, FontWeight.SemiBold), color = MonitorPalette.accent,
                            modifier = Modifier.monitorChromeClickable { action(MonitorMediaDeliveryValue.Action.RetryProjects) })
                    }
                    service.choices != null -> {
                        var expanded by remember { mutableStateOf(false) }
                        Box {
                            Row(Modifier.fillMaxWidth().deliveryOptionPlate().monitorChromeClickable { expanded = true }
                                .padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                MonitorIcon(MonitorIcon.FOLDER, null, Modifier.size(14.dp), MonitorPalette.muted)
                                Text(service.selectedProjectLabel ?: "Select a project",
                                    Modifier.weight(1f), style = MonitorTypography.text(13f, FontWeight.SemiBold), color = MonitorPalette.text)
                                MonitorIcon(MonitorIcon.CHEVRONS_UP_DOWN, null, Modifier.size(11.dp), MonitorPalette.muted)
                            }
                            DropdownMenu(expanded, onDismissRequest = { expanded = false }) {
                                if (service.choices.isEmpty()) DropdownMenuItem(text = { Text("No projects") }, onClick = {}, enabled = false)
                                service.choices.forEach { choice ->
                                    DropdownMenuItem(text = { Text(choice.label) }, onClick = {
                                        expanded = false; action(MonitorMediaDeliveryValue.Action.Selection(MonitorMediaDeliveryValue.Selection.PROJECT, choice.id))
                                    })
                                }
                            }
                        }
                        if (service.allowsCreation) Text("Create new project", style = MonitorTypography.text(13f, FontWeight.SemiBold), color = MonitorPalette.text,
                            modifier = Modifier.fillMaxWidth().deliveryOptionPlate().monitorChromeClickable {
                                action(MonitorMediaDeliveryValue.Action.CreateProject)
                            }.padding(12.dp))
                    }
                }
            }
        }
    }
}

@Composable private fun DeliveryExport(export: MonitorMediaDeliveryValue.Export, action: (MonitorMediaDeliveryValue.Action) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        DeliverySectionHeader("EXPORT")
        export.filename?.let { filename ->
            Column(Modifier.fillMaxWidth().deliveryOptionPlate().padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("Filename", style = MonitorTypography.text(12f, FontWeight.SemiBold), color = MonitorPalette.muted)
                Text(filename, style = MonitorTypography.readout(13f), color = MonitorPalette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        export.convertLog?.let { DeliveryToggle(it, MonitorMediaDeliveryValue.Option.CONVERT_LOG, action) }
        export.outputCurve?.let { DeliveryChoices(it, MonitorMediaDeliveryValue.Selection.OUTPUT_CURVE, action) }
        export.bakeLUT?.let { DeliveryToggle(it, MonitorMediaDeliveryValue.Option.BAKE_LUT, action) }
        export.bakeExposure?.let { DeliveryToggle(it, MonitorMediaDeliveryValue.Option.BAKE_EXPOSURE, action) }
        export.format?.let { DeliveryChoices(it, MonitorMediaDeliveryValue.Selection.FORMAT, action) }
        export.includeMetadata?.let { DeliveryToggle(it, MonitorMediaDeliveryValue.Option.INCLUDE_METADATA, action) }
        export.reupload?.let { DeliveryToggle(it, MonitorMediaDeliveryValue.Option.REUPLOAD, action) }
    }
}
@Composable private fun DeliveryToggle(toggle: MonitorMediaDeliveryValue.Toggle, option: MonitorMediaDeliveryValue.Option,
    action: (MonitorMediaDeliveryValue.Action) -> Unit) {
    Row(Modifier.fillMaxWidth().deliveryOptionPlate().padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f)) {
            Text(toggle.title, style = MonitorTypography.text(12.5f, FontWeight.SemiBold),
                color = if (toggle.enabled) MonitorPalette.text else MonitorPalette.faint)
            Text(toggle.help, style = MonitorTypography.text(10.5f), color = MonitorPalette.muted)
        }
        Switch(toggle.isOn, { action(MonitorMediaDeliveryValue.Action.Option(option, it)) }, enabled = toggle.enabled,
            modifier = Modifier.semantics { contentDescription = toggle.title },
            colors = SwitchDefaults.colors(checkedTrackColor = MonitorPalette.accent))
    }
}
@Composable private fun DeliveryChoices(choices: MonitorMediaDeliveryValue.Choices, selection: MonitorMediaDeliveryValue.Selection,
    action: (MonitorMediaDeliveryValue.Action) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (choices.title.isNotEmpty()) Text(choices.title, style = MonitorTypography.text(12.5f, FontWeight.SemiBold), color = MonitorPalette.text)
        choices.help?.let { Text(it, style = MonitorTypography.text(10.5f), color = MonitorPalette.muted) }
        MonitorSettingsChoices<String?>(options = choices.options.map { it.id }, selected = choices.selectedID, accentSelection = true,
            title = { id -> choices.options.firstOrNull { it.id == id }?.label ?: "" },
            onSelect = { id -> if (id != null) action(MonitorMediaDeliveryValue.Action.Selection(selection, id)) })
    }
}
@Composable private fun DeliverySectionHeader(title: String) {
    Text(title, style = MonitorTypography.readout(10f, FontWeight.Bold), color = MonitorPalette.muted)
}
@Composable private fun DeliveryBusy(title: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        CircularProgressIndicator(Modifier.size(16.dp), color = MonitorPalette.accent, strokeWidth = 2.dp)
        Text(title, style = MonitorTypography.text(12f), color = MonitorPalette.muted)
    }
}
@Composable private fun DeliveryActionButton(title: String, enabled: Boolean, modifier: Modifier = Modifier, action: () -> Unit) {
    Box(modifier.fillMaxWidth().clip(DeliveryOptionShape)
        .background(if (enabled) MonitorPalette.accent.copy(alpha = .22f) else MonitorPalette.border.copy(alpha = .25f))
        .border(1.dp, if (enabled) MonitorPalette.accent.copy(alpha = .55f) else MonitorPalette.border, DeliveryOptionShape)
        .monitorChromeClickable(enabled = enabled, onClick = action).padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
        Text(title, style = MonitorTypography.text(12.5f, FontWeight.SemiBold), color = if (enabled) MonitorPalette.text else MonitorPalette.faint)
    }
}
private fun Modifier.deliveryOptionPlate(opacity: Float = .04f): Modifier = clip(DeliveryOptionShape)
    .background(Color.White.copy(alpha = opacity), DeliveryOptionShape)

/** Existing four-parameter/trailing-lambda contract retains its compact default rendering. */
@Composable
fun MonitorMediaDeliveryProgress(
    value: MonitorMediaDeliveryProgressValue,
    onCancel: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    destinationIcon: @Composable () -> Unit,
) {
    MonitorMediaDeliveryProgress(value, onCancel, modifier, onExpand = null, destinationIcon = destinationIcon)
}

/** An optional independent expansion action leaves cancellation owned by the same host. */
@Composable
fun MonitorMediaDeliveryProgress(
    value: MonitorMediaDeliveryProgressValue,
    onCancel: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    onExpand: (() -> Unit)? = null,
    destinationIcon: @Composable () -> Unit,
) {
    val shape = RoundedCornerShape(50)
    Box(modifier.fillMaxWidth().shadow(12.dp, shape, ambientColor = Color.Black.copy(alpha = .35f))
        .clip(shape).monitorMaterial(MonitorMaterial.Delivery, shape).padding(horizontal = 14.dp, vertical = 11.dp)) {
        MonitorMediaDeliveryProgressContent(value, onCancel, onExpand, destinationIcon = destinationIcon)
    }
}
