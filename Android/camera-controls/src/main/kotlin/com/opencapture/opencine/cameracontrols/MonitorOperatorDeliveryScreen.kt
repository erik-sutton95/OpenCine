package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.DialogWindowProvider
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorMediaDeliveryPanel
import com.opencapture.monitorui.MonitorMediaDeliveryProgress
import com.opencapture.monitorui.MonitorMediaDeliveryProgressValue
import com.opencapture.monitorui.MonitorMediaDeliveryValue
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.appkit.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext
import java.io.File

/** Real original read operations and canonical record mapping; no gallery scheduling policy. */
class MonitorOriginalDeliverySource<R, P>(
    val library: MonitorMediaLibraryModel<P>, val record: (R) -> MonitorMediaRecord<P>?,
    val fileFacts: (R) -> MonitorDeliveryFileFacts, val connected: () -> Boolean?,
    val originals: MonitorDeliveryOriginalService<R>, val exporter: MonitorDeliveryExportService<R, File>,
) {
    fun selection(files: List<R>) = MonitorDeliverySelectionFacts(files.map(fileFacts), files.count(originals.available), connected())
    fun admission(files: List<R>): MonitorDeliveryAdmission? {
        val token = library.actionToken; val directory = library.cache.directory; val generation = directory.generation
        val captured = files.map { record(it) ?: return null }
        return MonitorDeliveryAdmission {
            library.isCurrent(token) && directory.generation == generation && captured.all { old ->
                library.record(old.asset.id)?.let { it.asset == old.asset && it.address == old.address } == true
            } && library.isCurrent(token) && directory.generation == generation
        }
    }
}

/** Complete native-share presentation over the existing delivery and preparation owners. */
@Composable
fun <R, P> MonitorOperatorDeliveryHost(
    files: List<R>?, source: MonitorOriginalDeliverySource<R, P>, mediaShare: MediaShare,
    mimeType: (String) -> String, onDismissPopup: () -> Unit,
    onPresentationChange: (Boolean) -> Unit = {},
) {
    val context = LocalContext.current
    val scope = remember(source) { CoroutineScope(SupervisorJob() + Dispatchers.Main) }
    val delivery = remember(scope) { MonitorDeliveryModel<MediaDeliveryOverlayState, MediaDeliveryResult, Unit>(scope) }
    DisposableEffect(delivery, scope) { onDispose { delivery.close(); scope.cancel() } }
    val state by delivery.state.collectAsState()
    SideEffect { onPresentationChange(files != null || state.running) }
    if (files == null && !state.running && state.progress == null && state.toast == null) return
    Box(Modifier.fillMaxSize()) {
        files?.let { selection ->
            val admission = remember(source, selection) { source.admission(selection) }
            val preparation = remember(scope, source, selection) {
                MonitorDeliveryPreparationModel<Unit, Unit, Unit, Unit, Unit>(scope,
                    observeSelection = { source.selection(selection) }, configuration = null, exportOptions = null,
                    sourceCurrent = { admission?.isCurrent() == true })
            }
            DisposableEffect(preparation) { preparation.start(); onDispose { preparation.close() } }
            MonitorOperatorDeliveryPopupOverlay(preparation, onClose = onDismissPopup, busy = state.running,
                onBegin = { request ->
                    val captured = admission
                    delivery.beginAdmitted(onComplete = { result -> admittedDeliveryToast(result) {
                        mediaShare.shareFiles(context, it, mimeType)
                    } }) { progress, run ->
                        progress(MediaDeliveryOverlayState("Preparing…", isPreparing = true))
                        if (captured == null) MonitorDeliveryCompletion(MediaDeliveryResult.Message("Selection is no longer available."))
                        else {
                            val admitted = MonitorDeliveryAdmission { run.isCurrent() && captured.isCurrent() && run.isCurrent() }
                            val outcome = MonitorDeliveryModel.runBatch<R, File, Unit>(
                                records = selection, destination = request.destination, action = request.action, admission = admitted,
                                originals = source.originals, exporter = source.exporter,
                                share = { MonitorDeliveryShareFiles(it) },
                                photos = MonitorDeliveryPhotosService.PerItem { file ->
                                    if (!admitted.isCurrent()) false else withContext(Dispatchers.IO) {
                                        if (!admitted.isCurrent()) false else mediaShare.insertIntoGallery(context, file, mimeType(file.name)) != null
                                    }
                                }, filename = { source.fileFacts(it).filename }, artifactFilename = { it.name },
                                progress = { it.androidOverlay(request.action)?.let(progress) })
                            MonitorDeliveryCompletion(outcome.androidResult())
                        }
                    }
                })
        }
        state.progress?.let { MonitorOperatorDeliveryProgress(it, delivery::cancel,
            Modifier.align(Alignment.TopCenter).statusBarsPadding().padding(horizontal = 20.dp, vertical = 12.dp)) }
        state.toast?.let { MonitorOperatorDeliveryToast(it, Modifier.align(Alignment.BottomCenter)) }
    }
}

@Composable
fun <C, F, P, X, H> MonitorOperatorDeliveryPopupOverlay(
    model: MonitorDeliveryPreparationModel<C, F, P, X, H>, onClose: () -> Unit, busy: Boolean = false,
    onBegin: (MonitorDeliveryPreparedRequest<C, F, H>) -> Unit,
    remoteArtwork: @Composable () -> Unit = { MonitorIcon(MonitorIcon.UPLOAD, null, Modifier.size(18.dp), MonitorPalette.text) },
) {
    val state by model.state.collectAsState()
    val serviceName = model.remotePresentation?.displayName ?: "Upload service"
    var showCreate by remember(model) { mutableStateOf(false) }
    var name by remember(model) { mutableStateOf("") }
    var showHop by remember(model) { mutableStateOf(false) }
    fun close() { model.close(); onClose() }
    Dialog(onDismissRequest = {
        when { busy -> Unit; state.step == MonitorDeliveryPreparationModel.Step.OPTIONS -> model.back(); else -> close() }
    }, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        val view = LocalView.current
        DisposableEffect(view) {
            (view.parent as? DialogWindowProvider)?.window?.let { it.setDimAmount(0f); applyMonitorSystemBars(it) }
            onDispose { }
        }
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = .42f)).clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null) { if (!busy) close() },
            contentAlignment = Alignment.BottomCenter) {
            MonitorMediaDeliveryPanel(value = deliveryPanelValue(model, busy),
                onAction = { action -> when (action) {
                    MonitorMediaDeliveryValue.Action.Close -> if (!busy) close()
                    MonitorMediaDeliveryValue.Action.Back -> if (!busy) model.back()
                    MonitorMediaDeliveryValue.Action.Begin -> if (!busy) model.takeRequest()?.let { onClose(); onBegin(it) }
                    MonitorMediaDeliveryValue.Action.HopToInternet -> showHop = true
                    MonitorMediaDeliveryValue.Action.RetryProjects -> model.loadProjects()
                    MonitorMediaDeliveryValue.Action.CreateProject -> { name = ""; showCreate = true }
                    is MonitorMediaDeliveryValue.Action.Destination -> MonitorDeliveryDestination.entries.firstOrNull { it.name == action.id }?.let(model::selectDestination)
                    is MonitorMediaDeliveryValue.Action.Option -> when (action.option) {
                        MonitorMediaDeliveryValue.Option.CONVERT_LOG -> model.setConvertLog(action.on)
                        MonitorMediaDeliveryValue.Option.BAKE_LUT -> model.setBakeLUT(action.on)
                        MonitorMediaDeliveryValue.Option.BAKE_EXPOSURE -> model.updateConfiguration { it.copy(bakeLUTExposure = action.on) }
                        MonitorMediaDeliveryValue.Option.INCLUDE_METADATA -> model.updateConfiguration { it.copy(includeMetadata = action.on) }
                        MonitorMediaDeliveryValue.Option.REUPLOAD -> model.updateConfiguration { it.copy(forceReupload = action.on) }
                    }
                    is MonitorMediaDeliveryValue.Action.Selection -> when (action.selection) {
                        MonitorMediaDeliveryValue.Selection.OUTPUT_CURVE -> model.exportOptions?.curves?.firstOrNull { it.id == action.id }?.let { choice -> model.updateConfiguration { it.copy(logTransform = choice.value) } }
                        MonitorMediaDeliveryValue.Selection.FORMAT -> model.exportOptions?.formats?.firstOrNull { it.id == action.id }?.let { choice -> model.updateConfiguration { it.copy(exportFormat = choice.value) } }
                        MonitorMediaDeliveryValue.Selection.POST_EXPORT -> MonitorDeliveryPostExportAction.entries.firstOrNull { it.name == action.id }?.let(model::setAction)
                        MonitorMediaDeliveryValue.Selection.PROJECT -> model.selectProject(action.id)
                    }
                } }, modifier = Modifier.navigationBarsPadding().padding(horizontal = 12.dp, vertical = 10.dp).widthIn(max = 620.dp).fillMaxWidth(),
                destinationIcon = { id -> if (id == MonitorDeliveryDestination.REMOTE_UPLOAD.name) remoteArtwork()
                    else MonitorIcon(MonitorIcon.SHARE, null, Modifier.size(18.dp), MonitorPalette.text) })
        }
    }
    if (showCreate) AlertDialog(onDismissRequest = { showCreate = false }, title = { Text("New $serviceName project") },
        text = { Column { Text("Creates a blank project in your workspace."); TextField(name, { name = it }, label = { Text("Project name") }) } },
        confirmButton = { TextButton(enabled = name.trim().isNotEmpty(), onClick = { val captured = name; name = ""; showCreate = false; model.createProject(captured) }) { Text("Create") } },
        dismissButton = { TextButton(onClick = { name = ""; showCreate = false }) { Text("Cancel") } })
    if (showHop) AlertDialog(onDismissRequest = { showHop = false }, title = { Text("Leave camera Wi-Fi?") },
        text = { Text("We'll hop to home Wi-Fi or cellular so you can sign in and pick a project. The camera reconnects automatically when you're done.") },
        confirmButton = { TextButton(onClick = { showHop = false; model.hopToInternet() }) { Text("Hop") } },
        dismissButton = { TextButton(onClick = { showHop = false }) { Text("Cancel") } })
}

private fun <C, F, P, X, H> deliveryPanelValue(model: MonitorDeliveryPreparationModel<C, F, P, X, H>, busy: Boolean): MonitorMediaDeliveryValue {
    val state = model.state.value
    val serviceName = model.remotePresentation?.displayName ?: "Upload service"; val selection = state.selection; val remote = state.remoteFacts; val config = state.configuration; val options = model.exportOptions
    val notices = buildList {
        selection.cachedCount?.let { cached -> if (cached < selection.files.size) {
            if (selection.connected == true) add(MonitorMediaDeliveryValue.Notice("${selection.files.size - cached} on-camera clip(s) will be cached from the camera first."))
            else if (selection.connected == false) add(MonitorMediaDeliveryValue.Notice("${selection.files.size - cached} on-camera clip(s) will be skipped; reconnect to cache them."))
        } }
        if (state.destination == MonitorDeliveryDestination.REMOTE_UPLOAD && remote?.configured == false)
            add(MonitorMediaDeliveryValue.Notice("$serviceName isn't configured; add credentials in Settings → Storage.", true))
        else if (state.destination == MonitorDeliveryDestination.REMOTE_UPLOAD && state.step == MonitorDeliveryPreparationModel.Step.OPTIONS)
            (model.selectedProject?.name ?: remote?.savedProjectName)?.let { add(MonitorMediaDeliveryValue.Notice("Project: $it")) }
    }
    val service = if (state.destination != MonitorDeliveryDestination.REMOTE_UPLOAD) null else if (model.internetGate) {
        val message = remote?.savedProjectName?.let { "$serviceName needs the internet. Hop off the camera's Wi-Fi to pick a project (currently “$it”) and upload; the camera reconnects automatically when you're done." }
            ?: "$serviceName needs the internet. Hop off the camera's Wi-Fi to sign in and pick a project; the camera reconnects automatically when you're done."
        MonitorMediaDeliveryValue.Service.InternetGate(serviceName.uppercase(), message, state.hopping)
    } else MonitorMediaDeliveryValue.Service.Projects("PROJECT", "Upload destination in your $serviceName workspace.",
        if (remote?.connected == false) "Sign in to $serviceName from Settings → Storage to upload." else null,
        state.projectsLoading, state.projectsError, if (state.listing == null) null else model.uploadableProjects.map { MonitorMediaDeliveryValue.Choice(it.id, it.name) },
        state.selectedProjectID, selectedLabel = remote?.savedProjectName)
    val export = if (!model.internetGate && config != null && options != null) {
        val lut = options.lutAvailable(); val convert = options.convertLogAvailable(); val exposure = options.bakeExposureAvailable()
        MonitorMediaDeliveryValue.Export(options.filename(config),
            convertLog = convert?.let { MonitorMediaDeliveryValue.Toggle("Convert log", if (it) options.convertHelp else options.convertUnavailableHelp, config.convertLog, it) },
            outputCurve = if (config.convertLog) MonitorMediaDeliveryValue.Choices("Output curve", options = options.curves.map { MonitorMediaDeliveryValue.Choice(it.id, it.label) }, selectedID = options.curves.firstOrNull { it.value == config.logTransform }?.id) else null,
            bakeLUT = MonitorMediaDeliveryValue.Toggle("Bake LUT", if (lut == true) options.lutLabel()?.let { "Apply $it to exports." } ?: "Apply the selected LUT to exports." else "No LUT selected. Pick one in view assists.", config.bakeLUT, lut == true),
            bakeExposure = if (config.bakeLUT && exposure != null) MonitorMediaDeliveryValue.Toggle("Bake exposure", "Write the LUT exposure pull into the file so it matches the monitor. Off bakes the cube at 0.0.", config.bakeLUTExposure, lut == true && exposure) else null,
            format = if ((config.bakeLUT || config.convertLog || state.destination == MonitorDeliveryDestination.NATIVE_SHARE) &&
                (state.destination != MonitorDeliveryDestination.REMOTE_UPLOAD || options.formatsForRemoteUpload == true)) MonitorMediaDeliveryValue.Choices("Format", "MOV preserves quality; MP4 is more widely compatible.", options.formats.map { MonitorMediaDeliveryValue.Choice(it.id, it.label) }, options.formats.firstOrNull { it.value == config.exportFormat }?.id) else null,
            includeMetadata = MonitorMediaDeliveryValue.Toggle("Include metadata", "Filename, capture date, and size (best-effort JSON sidecar).", config.includeMetadata),
            reupload = if (state.destination == MonitorDeliveryDestination.REMOTE_UPLOAD) MonitorMediaDeliveryValue.Toggle("Re-upload already uploaded", "Skip clips already on $serviceName unless enabled.", config.forceReupload) else null)
    } else if (!model.internetGate && state.step == MonitorDeliveryPreparationModel.Step.OPTIONS && selection.files.size == 1) MonitorMediaDeliveryValue.Export(filename = selection.files.first().filename) else null
    return MonitorMediaDeliveryValue(if (state.step == MonitorDeliveryPreparationModel.Step.DESTINATION) MonitorMediaDeliveryValue.Step.DESTINATION else MonitorMediaDeliveryValue.Step.OPTIONS,
        title = state.destination?.title(model.remotePresentation?.displayName) ?: "Share", selectionLabel = "${selection.files.size} clip${if (selection.files.size == 1) "" else "s"}", notices = notices,
        destinations = listOfNotNull(MonitorMediaDeliveryValue.Destination(MonitorDeliveryDestination.NATIVE_SHARE.name, "Share", "Nearby Share, Files, and other apps", model.destinationEnabled(MonitorDeliveryDestination.NATIVE_SHARE)),
            if (remote != null) MonitorMediaDeliveryValue.Destination(MonitorDeliveryDestination.REMOTE_UPLOAD.name, MonitorDeliveryDestination.REMOTE_UPLOAD.title(model.remotePresentation?.displayName), MonitorDeliveryDestination.REMOTE_UPLOAD.subtitle(model.remotePresentation?.displayName), model.destinationEnabled(MonitorDeliveryDestination.REMOTE_UPLOAD)) else null),
        upcoming = MediaDeliveryUpcoming.titles, service = service, export = export,
        footer = if (state.step == MonitorDeliveryPreparationModel.Step.OPTIONS && !model.internetGate) MonitorMediaDeliveryValue.Footer(
            postExport = if (state.destination == MonitorDeliveryDestination.NATIVE_SHARE) MonitorMediaDeliveryValue.Choices("", options = listOf(
                MonitorMediaDeliveryValue.Choice(MonitorDeliveryPostExportAction.SYSTEM_SHARE.name, "Share"), MonitorMediaDeliveryValue.Choice(MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS.name, "Save to Photos")), selectedID = state.action.name) else null,
            actionTitle = if (state.destination == MonitorDeliveryDestination.REMOTE_UPLOAD) "Upload" else if (state.action == MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS) "Save to Photos" else "Share", enabled = model.canContinue && !busy) else null)
}

@Composable
fun MonitorOperatorDeliveryProgress(state: MediaDeliveryOverlayState, onCancel: (() -> Unit)? = null, modifier: Modifier = Modifier) {
    MonitorMediaDeliveryProgress(MonitorMediaDeliveryProgressValue(state.statusLine, state.batchLine, state.overallFraction, state.isPreparing), onCancel,
        modifier.widthIn(max = 420.dp), destinationIcon = { MonitorIcon(MonitorIcon.SHARE, null, Modifier.size(13.dp), MonitorPalette.accent) })
}
@Composable
fun MonitorOperatorDeliveryToast(message: String, modifier: Modifier = Modifier) {
    Text(message, style = MonitorTypography.text(13f, FontWeight.Medium), color = MonitorPalette.text,
        modifier = modifier.navigationBarsPadding().padding(bottom = 28.dp).clip(MediaCapsuleShape)
            .background(MonitorPalette.surface, MediaCapsuleShape).border(1.dp, Color.White.copy(alpha = .10f), MediaCapsuleShape)
            .padding(horizontal = 16.dp, vertical = 10.dp))
}
