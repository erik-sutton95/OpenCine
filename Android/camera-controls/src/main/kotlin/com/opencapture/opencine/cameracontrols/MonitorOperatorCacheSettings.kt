package com.opencapture.opencine.cameracontrols

import android.text.format.Formatter
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.Color
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.settings.MonitorCacheSettings
import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.MonitorSettingsCacheIdentity
import com.opencapture.opencine.appkit.MonitorSettingsCacheModel
import com.opencapture.opencine.appkit.MonitorSettingsCacheSource

/** One presentation owner serves production setup and a public-session scene. */
@Composable
public fun <P> MonitorOperatorCacheSettings(library: MonitorMediaLibraryModel<P>, cacheOriginals: Boolean,
    onCacheOriginals: (Boolean) -> Unit) {
    val value by library.state.collectAsState()
    val admission = library.actionToken
    val revision = value.cacheRevision
    val source = MonitorSettingsCacheSource(
        MonitorSettingsCacheIdentity(library.cache.directory.root.absolutePath, value.lifetimeToken.toString()),
        revision,
        isCurrent = { library.isCurrent(admission) && library.state.value.cacheRevision == revision },
        count = { library.cache.directory.totalByteCount() },
        clear = { library.clearCache() },
    )
    MonitorOperatorCacheSettings(source, cacheOriginals, onCacheOriginals)
}

/** SDK adapters provide captured IO; this owner presents count, confirmation, progress and errors. */
@Composable
public fun MonitorOperatorCacheSettings(
    source: MonitorSettingsCacheSource,
    cacheOriginals: Boolean? = null,
    onCacheOriginals: ((Boolean) -> Unit)? = null,
    cacheHelp: String = "Keep originals downloaded for playback.",
    scopeHelp: String = "Originals and playback proxies downloaded from the camera.",
    clearHelp: String = "Remove downloaded picture files while keeping the clip list.",
    formatBytes: ((Long) -> String)? = null,
    feedback: () -> Unit = {},
    checkingLabel: String = "Checking…",
    readFailureLabel: String = "Could not read the cache.",
    clearFailureLabel: String = "Could not clear the cache. Try again.",
    confirmClear: Boolean = true,
    summaryColor: Color = MonitorPalette.accent,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val model = remember { MonitorSettingsCacheModel(scope) }
    val value by model.state.collectAsState()
    DisposableEffect(model) { onDispose { model.retire() } }
    LaunchedEffect(model, source.identity, source.revision) { model.refresh(source) }
    MonitorCacheSettings(cacheOriginals = cacheOriginals,
        sizeLabel = value.bytes?.let { bytes ->
            formatBytes?.invoke(bytes) ?: if (bytes == 0L) "Empty" else Formatter.formatFileSize(context, bytes)
        } ?: checkingLabel,
        clearing = value.clearing, cacheHelp = cacheHelp, scopeHelp = scopeHelp, clearHelp = clearHelp,
        onCacheOriginals = onCacheOriginals, clear = {
            model.requestClear()
            if (!confirmClear) model.clear()
        }, feedback = feedback)
    value.clearSummary?.let { Text(it, color = summaryColor) }
    if (value.readFailed || value.clearFailed) Text(value.failure ?: if (value.clearFailed) clearFailureLabel else readFailureLabel,
        color = MonitorPalette.accent)
    if (confirmClear && value.confirmationPresented) AlertDialog(
        onDismissRequest = model::cancelConfirmation,
        title = { Text("Clear cache?", color = LiveDesign.text) },
        text = { Text("Removes downloaded clip files from this phone. The clip list is kept.", color = LiveDesign.muted) },
        confirmButton = { TextButton(onClick = model::clear) { Text("Clear", color = MonitorPalette.recording) } },
        dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text("Cancel", color = LiveDesign.muted) } },
        containerColor = LiveDesign.surface,
    )
    if (confirmClear && value.clearFailed) AlertDialog(onDismissRequest = model::dismissError,
        title = { Text(value.failure ?: clearFailureLabel) },
        confirmButton = { TextButton(onClick = model::dismissError) { Text("OK") } })
}
