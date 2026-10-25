package com.opencapture.opencine.appkit

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorPalette

/** Chooser actions read the same in every app, never the host theme's accent. */
@Composable
private fun chooserButtonColors() = ButtonDefaults.textButtonColors(contentColor = MonitorPalette.text)

/** Shared chooser rendering, usable inside either a setup flow or a host's network wizard. */
@Composable
public fun AddSetupChooserView(
    chooser: AddSetupChooser,
    onSelect: (AddSetupOption) -> Unit,
    modifier: Modifier = Modifier,
    horizontal: Boolean = false,
    onNoticeAction: (String) -> Unit = {},
) {
    @Composable fun option(value: AddSetupOption, modifier: Modifier) {
        Column(modifier.background(MonitorPalette.tile, RoundedCornerShape(12.dp)).padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(value.title, color = MonitorPalette.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            Text(value.detail, color = MonitorPalette.muted, fontSize = 12.5.sp, lineHeight = 17.sp)
            TextButton(onClick = { chooser.select(value.id, onSelect) }, enabled = value.enabled, colors = chooserButtonColors(),
                modifier = Modifier.testTag("${chooser.identifierPrefix}.${value.id}")) {
                Text(value.actionTitle)
            }
        }
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(chooser.title, color = MonitorPalette.text, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        if (chooser.detail.isNotEmpty()) Text(chooser.detail, color = MonitorPalette.muted, fontSize = 13.sp, lineHeight = 18.sp)
        chooser.notice?.let { notice ->
            Text(notice.message, color = MonitorPalette.muted, fontSize = 12.5.sp)
            TextButton(onClick = { onNoticeAction(notice.id) }, colors = chooserButtonColors()) { Text(notice.actionTitle) }
        }
        if (horizontal && chooser.options.size == 2) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                chooser.options.forEach { option(it, Modifier.weight(1f)) }
            }
        } else {
            chooser.options.forEach { option(it, Modifier.fillMaxWidth()) }
        }
        chooser.footer?.let { Text(it, color = MonitorPalette.muted, fontSize = 12.sp) }
    }
}

/** A typed chooser followed, if needed, by integration-owned network or credential steps. */
public class AddSetupFlow(
    public val chooser: AddSetupChooser,
    public val onSelect: (AddSetupOption) -> Unit,
    public val destination: (@Composable (AddSetupOption) -> Unit)? = null,
    public val initialSelection: String? = null,
    public val onDismiss: () -> Unit = {},
    public val onNoticeAction: (String) -> Unit = {},
    public val onCancel: () -> Unit = {},
    public val cancelTitle: String? = "Cancel",
)

/** Renders the shared choice before an optional integration destination; dismissal sends no command itself. */
@Composable
public fun AddSetupFlowView(flow: AddSetupFlow, modifier: Modifier = Modifier) {
    var selected by remember { mutableStateOf(flow.initialSelection) }
    DisposableEffect(Unit) { onDispose { flow.onDismiss() } }
    val option = flow.chooser.options.firstOrNull { it.id == selected && it.enabled }
    val destination = flow.destination
    if (option != null && destination != null) {
        destination(option)
    } else {
        Column(modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            AddSetupChooserView(flow.chooser, onSelect = {
                if (destination != null) selected = it.id else flow.onSelect(it)
            }, onNoticeAction = flow.onNoticeAction)
            flow.cancelTitle?.let { TextButton(onClick = flow.onCancel, colors = chooserButtonColors()) { Text(it) } }
        }
    }
}
