package com.opencapture.opencine.cameracontrols

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
import androidx.compose.ui.graphics.Color
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.settings.MonitorCacheSettings
import com.opencapture.opencine.appkit.MonitorMediaLibraryModel
import com.opencapture.opencine.appkit.settingsCacheSource
import com.opencapture.opencine.appkit.MonitorSettingsCacheModel
import com.opencapture.opencine.appkit.MonitorSettingsCacheSource

/** One presentation owner serves production setup and a public-session scene. */
@Composable
public fun <P> MonitorOperatorCacheSettings(library: MonitorMediaLibraryModel<P>, cacheOriginals: Boolean,
    onCacheOriginals: (Boolean) -> Unit) {
    MonitorOperatorCacheSettings(monitorSettingsCacheSource(library), cacheOriginals, onCacheOriginals)
}

/** The settings cache source over the gallery's [library], renewed with its lifetime and cache revision. */
@Composable
public fun <P> monitorSettingsCacheSource(library: MonitorMediaLibraryModel<P>): MonitorSettingsCacheSource {
    val value by library.state.collectAsState()
    return library.settingsCacheSource(value)
}

/**
 * SDK adapters provide captured IO; this owner presents count, confirmation, progress and errors.
 * Clearing always asks first (the Pocket baseline): one policy for every app.
 */
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
    summaryColor: Color = MonitorPalette.accent,
) {
    val scope = rememberCoroutineScope()
    val model = remember { MonitorSettingsCacheModel(scope) }
    val value by model.state.collectAsState()
    DisposableEffect(model) { onDispose { model.retire() } }
    LaunchedEffect(model, source.identity, source.revision) { model.refresh(source) }
    MonitorCacheSettings(cacheOriginals = cacheOriginals,
        sizeLabel = value.bytes?.let { bytes ->
            formatBytes?.invoke(bytes) ?: formatCacheSize(bytes)
        } ?: checkingLabel,
        clearing = value.clearing, cacheHelp = cacheHelp, scopeHelp = scopeHelp, clearHelp = clearHelp,
        onCacheOriginals = onCacheOriginals, clear = model::requestClear, feedback = feedback)
    value.clearSummary?.let { Text(it, color = summaryColor) }
    if (value.readFailed || value.clearFailed) Text(value.failure ?: if (value.clearFailed) clearFailureLabel else readFailureLabel,
        color = MonitorPalette.accent)
    if (value.confirmationPresented) AlertDialog(
        onDismissRequest = model::cancelConfirmation,
        title = { Text("Clear cache?", color = LiveDesign.text) },
        text = { Text("Removes downloaded clip files from this phone. The clip list is kept.", color = LiveDesign.muted) },
        confirmButton = { TextButton(onClick = model::clear) { Text("Clear", color = MonitorPalette.recording) } },
        dismissButton = { TextButton(onClick = model::cancelConfirmation) { Text("Cancel", color = LiveDesign.muted) } },
        containerColor = LiveDesign.surface,
    )
    if (value.clearFailed) AlertDialog(onDismissRequest = model::dismissError,
        title = { Text(value.failure ?: clearFailureLabel) },
        confirmButton = { TextButton(onClick = model::dismissError) { Text("OK") } })
}
