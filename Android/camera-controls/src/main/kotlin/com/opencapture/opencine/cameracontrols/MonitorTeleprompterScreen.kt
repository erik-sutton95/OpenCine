package com.opencapture.opencine.cameracontrols

import android.content.ClipboardManager
import android.content.Context
import android.view.WindowManager
import androidx.activity.compose.LocalActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.findViewTreeLifecycleOwner
import com.opencapture.monitorui.TeleprompterReader
import com.opencapture.opencine.appkit.MonitorTeleprompterModel
import kotlinx.coroutines.launch

/** In-app script import, preview and editing. Only Use script replaces the saved offline copy. */
@Composable
public fun MonitorTeleprompterScreen(model: MonitorTeleprompterModel, onClose: () -> Unit,
    onUseScript: (() -> Unit)? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var editing by remember { mutableStateOf(false) }
    var reading by remember { mutableStateOf(false) }
    var showLink by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    var link by remember { mutableStateOf("") }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch { model.load { MonitorTeleprompterImport.document(context.contentResolver, uri) } }
    }
    MonitorTeleprompterLifetime(model)
    DisposableEffect(model) {
        model.pause()
        onDispose { model.pause(); model.cancelImport() }
    }
    BackHandler {
        when {
            reading -> { model.pause(); reading = false }
            editing -> { model.cancelImport(); editing = false }
            model.candidate != null || model.busy -> model.cancelImport()
            else -> onClose()
        }
    }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        val script = model.script
        if (reading && script != null) {
            Box(Modifier.fillMaxSize().testTag("teleprompter.reader").safeDrawingPadding()) {
                TeleprompterReader(script.text, model.fontSize, model.speed, model.mirrored, 1f,
                    model.playing, model.position, model::seek, model::pause, model::togglePlayback, model::reset,
                    Modifier.fillMaxSize(), onSettings = { model.pause(); reading = false })
            }
        }
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        if (!reading) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(if (editing) "Edit script" else "Teleprompter", color = Color.White, fontSize = 20.sp)
            Spacer(Modifier.weight(1f))
            if (editing) {
                OutlinedButton(onClick = { model.cancelImport(); editing = false }) { Text("Cancel") }
                Button(onClick = { scope.launch {
                    model.previewText(draft, edited = true)
                    if (model.useCandidate()) editing = false
                } }, enabled = !model.busy) { Text("Done") }
            } else {
                if (script != null) OutlinedButton(onClick = { model.pause(); reading = true },
                    modifier = Modifier.testTag("teleprompter.read")) { Text("Read") }
                OutlinedButton(onClick = onClose, modifier = Modifier.testTag("teleprompter.close")) { Text("Close") }
            }
        }
        if (reading) {
            Spacer(Modifier.weight(1f))
        } else if (editing) {
            OutlinedTextField(draft, { draft = it }, label = { Text("Script") },
                modifier = Modifier.weight(1f).fillMaxWidth().testTag("teleprompter.script.editor"))
            model.error?.let { Text(it, color = Color(0xFFFFA59D)) }
        } else {
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState())
                .testTag("teleprompter.manager.controls"), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (script != null && model.candidate == null) {
                    Text(script.name, color = Color.White, fontSize = 18.sp)
                    Text(script.sourceUrl ?: "Saved on this device", color = Color.LightGray)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(onClick = { model.cancelImport(); model.pause(); draft = script.text; editing = true },
                            modifier = Modifier.testTag("teleprompter.edit")) { Text("Edit") }
                        if (script.sourceUrl != null) OutlinedButton(onClick = { scope.launch { script.sourceUrl?.let { source -> model.load { MonitorTeleprompterImport.remote(source) } } } },
                            enabled = !model.busy, modifier = Modifier.testTag("teleprompter.import.refresh")) { Text("Refresh") }
                    }
                }
                Text("Add script", color = Color.White, fontSize = 18.sp)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val text = clipboard.primaryClip?.getItemAt(0)?.text?.toString().orEmpty()
                        scope.launch { model.previewText(text) }
                    }, enabled = !model.busy, modifier = Modifier.testTag("teleprompter.import.paste")) { Text("Paste") }
                    OutlinedButton(onClick = { importer.launch(arrayOf("text/*", "application/octet-stream")) },
                        enabled = !model.busy, modifier = Modifier.testTag("teleprompter.import.file")) { Text("Import file") }
                    OutlinedButton(onClick = { showLink = !showLink }, enabled = !model.busy,
                        modifier = Modifier.testTag("teleprompter.import.link")) { Text("Link") }
                }
                if (script == null) Text("Paste text, choose a TXT or Markdown file, or load a direct HTTPS text link.", color = Color.LightGray)
                if (showLink) {
                    OutlinedTextField(link, { link = it }, label = { Text("Script URL") }, singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("teleprompter.import.url"))
                    Button(onClick = { scope.launch { model.load { MonitorTeleprompterImport.remote(link) } } }, enabled = !model.busy, modifier = Modifier.testTag("teleprompter.import.load")) { Text("Load preview") }
                }
                if (model.busy) Row(verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    CircularProgressIndicator()
                    OutlinedButton(onClick = model::cancelImport) { Text("Cancel loading") }
                }
                model.error?.let { Text(it, color = Color(0xFFFFA59D), modifier = Modifier.testTag("teleprompter.error")) }
                model.candidate?.let { preview ->
                    Text("Preview: ${preview.name}", color = Color.White, fontSize = 18.sp)
                    preview.sourceUrl?.let { Text(it, color = Color.LightGray) }
                    Text(preview.text.take(4000), color = Color.White, modifier = Modifier.testTag("teleprompter.import.preview"))
                    if (preview.text.length > 4000) Text("Showing the first 4,000 characters.", color = Color.LightGray)
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(onClick = {
                            if (model.useCandidate()) onUseScript?.invoke()
                        }, modifier = Modifier.testTag("teleprompter.import.use")) { Text("Use script") }
                        OutlinedButton(onClick = model::cancelImport) { Text("Cancel") }
                    }
                }
                MonitorTeleprompterOptions(model)
            }
        }
    }
    }
}

/** Keeps playback paused across background transitions without changing any camera state. */
@Composable
internal fun MonitorTeleprompterLifetime(model: MonitorTeleprompterModel) {
    val lifecycle = LocalView.current.findViewTreeLifecycleOwner()?.lifecycle
    DisposableEffect(model, lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_PAUSE) model.pause() }
        lifecycle?.addObserver(observer)
        onDispose { lifecycle?.removeObserver(observer); model.pause() }
    }
}

/** The ordinary assist inspector's options, also available before connecting a camera. */
@Composable
internal fun MonitorTeleprompterOptions(model: MonitorTeleprompterModel, onManage: (() -> Unit)? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        onManage?.let { open ->
            OutlinedButton(onClick = { model.pause(); open() }, modifier = Modifier.testTag("teleprompter.manage")) {
                Text(if (model.hasScript) "Manage script" else "Add script")
            }
        }
        Text("Text ${model.fontSize.toInt()}", color = Color.White)
        Slider(model.fontSize, model::updateFontSize, valueRange = 24f..72f, steps = 23,
            modifier = Modifier.testTag("teleprompter.fontSize").semantics { contentDescription = "Text size" })
        Text("Speed ${model.speed.toInt()}", color = Color.White)
        Slider(model.speed, model::updateSpeed, valueRange = 10f..300f, steps = 144,
            modifier = Modifier.testTag("teleprompter.speed").semantics { contentDescription = "Scroll speed" })
        Text("Background ${(model.backgroundOpacity * 100).toInt()}%", color = Color.White)
        Slider(model.backgroundOpacity, model::updateBackgroundOpacity, valueRange = 0f..1f, steps = 19,
            modifier = Modifier.testTag("teleprompter.opacity").semantics { contentDescription = "Background opacity" })
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Live preview", color = Color.White, modifier = Modifier.weight(1f))
            Switch(model.showsPreview, model::updateShowsPreview, modifier = Modifier.testTag("teleprompter.preview").semantics { contentDescription = "Live preview" })
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Mirror text", color = Color.White, modifier = Modifier.weight(1f))
            Switch(model.mirrored, model::updateMirrored, modifier = Modifier.testTag("teleprompter.mirror").semantics { contentDescription = "Mirror text" })
        }
    }
}

/** A live monitor's script manager is modal, while its native picture owner stays mounted. */
@Composable
internal fun MonitorTeleprompterDialog(model: MonitorTeleprompterModel, onClose: () -> Unit, onUseScript: () -> Unit) {
    val keepAwake = (LocalActivity.current?.window?.attributes?.flags ?: 0) and
        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0
    Dialog(onDismissRequest = onClose,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val view = LocalView.current
        DisposableEffect(view, keepAwake) {
            val previous = view.keepScreenOn
            view.keepScreenOn = keepAwake
            onDispose { view.keepScreenOn = previous }
        }
        MonitorTeleprompterScreen(model, onClose, onUseScript)
    }
}

/** Frame-rate reading progress is observed only here, never by the native monitor composition. */
@Composable
internal fun MonitorTeleprompterOverlay(model: MonitorTeleprompterModel, modifier: Modifier, enabled: Boolean, onSettings: () -> Unit) {
    val script = model.script ?: return
    TeleprompterReader(script.text, model.fontSize, model.speed, model.mirrored,
        if (model.showsPreview) model.backgroundOpacity else 1f,
        model.playing, model.position, model::seek, model::pause, model::togglePlayback, model::reset, modifier, enabled, onSettings)
}
