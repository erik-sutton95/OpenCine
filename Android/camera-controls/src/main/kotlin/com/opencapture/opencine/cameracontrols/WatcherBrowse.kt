package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.MonitorWatcherPasscodeRule

/** Join facts from the existing relay owner, mirrored from Swift's WatcherJoinStatus. */
public sealed interface WatcherJoinStatus {
    public data object Idle : WatcherJoinStatus
    public data object Connecting : WatcherJoinStatus
    public data class Reconnecting(public val attempt: Int, public val maximum: Int) : WatcherJoinStatus
    public data object NeedsPasscode : WatcherJoinStatus
    public data object Live : WatcherJoinStatus
    public data class Failed(public val message: String) : WatcherJoinStatus
}

/** One discovered feed; an unreported camera name remains unknown. */
public data class WatcherFeedRow(public val id: String, public val name: String, public val cameraName: String? = null)

/** Typed values and actions for the same browse screen as Swift's WatcherBrowseHost. */
public interface WatcherBrowseHost {
    public val watcherJoinStatus: WatcherJoinStatus
    public val watcherFeeds: List<WatcherFeedRow>
    public val watcherBrowseError: String?
    public val watcherPasscodeError: String? get() = null
    public fun startWatcherBrowse()
    public fun joinWatcherFeed(id: String)
    public fun retryWatcherPasscode(code: String)
    public fun stopWatching()
}

/** Shared feed browse, progress and passcode UI; discovery, credentials and joining stay with the host. */
@Composable
public fun WatcherBrowse(
    host: WatcherBrowseHost,
    modifier: Modifier = Modifier,
    networkInstructions: String = "Join the same camera Wi-Fi as the sharing phone first. On that phone, open Operator Setup → Sharing → Show Wi-Fi code. Scan it with Camera, join the network, then return here.",
    emptyMessage: String = "No shared feeds on this network. Check that both devices joined the same camera Wi-Fi and Share this feed is on. Allow Local Network if asked.",
): Unit {
    var passcode by remember { mutableStateOf("") }
    val join = { MonitorWatcherPasscodeRule.answer(passcode)?.let(host::retryWatcherPasscode); Unit }
    BackHandler(onBack = host::stopWatching)
    LaunchedEffect(Unit) { host.startWatcherBrowse() }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Watch a feed", style = MonitorTypography.text(22f, FontWeight.Bold), color = MonitorPalette.text)
            TextButton(onClick = host::stopWatching) { Text("Close") }
        }
        Text(networkInstructions, style = MonitorTypography.text(13f), color = MonitorPalette.muted)
        Text("Already joined? Choose the shared feed below. Keep the camera connection inside the app on the sharing phone only.",
            style = MonitorTypography.text(13f), color = MonitorPalette.muted)
        Button(onClick = host::startWatcherBrowse) { Text("Find shared feeds") }
        when (val status = host.watcherJoinStatus) {
            WatcherJoinStatus.NeedsPasscode -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("This feed needs a passcode.", style = MonitorTypography.text(14f, FontWeight.Medium), color = MonitorPalette.text)
                host.watcherPasscodeError?.let { Text(it, color = MonitorPalette.recording) }
                OutlinedTextField(value = passcode, onValueChange = { passcode = it },
                    label = { Text("Passcode") }, singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                    keyboardActions = KeyboardActions(onGo = { join() }))
                Button(onClick = join, enabled = MonitorWatcherPasscodeRule.answer(passcode) != null) { Text("Join") }
            }
            is WatcherJoinStatus.Failed -> Text(status.message, color = MonitorPalette.recording)
            is WatcherJoinStatus.Reconnecting -> Text("Reconnecting… ${status.attempt} of ${status.maximum}", color = MonitorPalette.muted)
            WatcherJoinStatus.Connecting -> Text("Joining…", color = MonitorPalette.muted)
            else -> Unit
        }
        if (host.watcherFeeds.isEmpty()) {
            Text(host.watcherBrowseError ?: emptyMessage, style = MonitorTypography.text(14f), color = MonitorPalette.muted)
        } else {
            host.watcherFeeds.forEach { feed ->
                Column(Modifier.fillMaxWidth().clickable { host.joinWatcherFeed(feed.id) }.padding(vertical = 10.dp)) {
                    Text(feed.name, style = MonitorTypography.text(16f, FontWeight.SemiBold), color = MonitorPalette.text)
                    feed.cameraName?.takeIf { it.isNotEmpty() }?.let {
                        Text(it, style = MonitorTypography.text(12f), color = MonitorPalette.muted)
                    }
                }
            }
        }
    }
}
