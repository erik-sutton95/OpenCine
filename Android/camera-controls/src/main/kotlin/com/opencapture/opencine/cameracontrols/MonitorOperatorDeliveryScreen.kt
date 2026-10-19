package com.opencapture.opencine.cameracontrols

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.staticCompositionLocalOf
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
import com.opencapture.monitorui.MonitorMediaDeliveryProgressDetailsValue
import com.opencapture.monitorui.MonitorMediaDeliveryProgressPanel
import com.opencapture.monitorui.MonitorMediaDeliveryProgressValue
import com.opencapture.monitorui.MonitorMediaDeliveryValue
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.opencine.appkit.*
import com.opencapture.opencine.vocabulary.MediaClipFormatting
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Original read operations and canonical record mapping of one gallery; no scheduling policy.
 * A selection's admission is its cache content, never the gallery browse, so a delivery run
 * outlives the media screen that started it (A4-10).
 */
class MonitorOriginalDeliverySource<R, P>(
    val library: MonitorMediaLibraryModel<P>, val record: (R) -> MonitorMediaRecord<P>?,
    val fileFacts: (R) -> MonitorDeliveryFileFacts, val connected: () -> Boolean?,
    val originals: MonitorDeliveryOriginalService<R>, val exporter: MonitorDeliveryExportService<R, File>,
) {
    fun selection(files: List<R>) = MonitorDeliverySelectionFacts(files.map(fileFacts), files.count(originals.available), connected())
    fun admission(files: List<R>): MonitorDeliveryAdmission? {
        val directory = library.cache.directory; val generation = directory.generation
        val captured = files.map { record(it) ?: return null }
        // A record the gallery no longer lists stays admitted; its cache file is the truth.
        return MonitorDeliveryAdmission {
            directory.generation == generation && captured.all { old ->
                library.record(old.asset.id)?.let { it.asset == old.asset && it.address == old.address } ?: true
            } && directory.generation == generation
        }
    }
    /** The delivery source of these originals: each record is delivered as its cached file. */
    fun <C, F> source(metadata: (List<R>) -> String? = { null }) = MonitorDeliverySource<R, C, F>(originals,
        prepare = { record, _, report -> exporter.prepare(record, report) }, release = exporter.release,
        filename = { fileFacts(it).filename }, metadata = metadata)
}

/**
 * The delivery popup of a gallery that delivers originals only (no export choices or remote):
 * share and Photos through the app-scoped coordinator of the app root. A host composed without
 * that root (an instrumentation fixture) offers no delivery.
 */
@Composable
fun <R, P> MonitorOriginalDeliveryHost(
    files: List<R>?, source: MonitorOriginalDeliverySource<R, P>, photos: MonitorDeliveryPhotosService<File>,
    onDismissPopup: () -> Unit, onPresentationChange: (Boolean) -> Unit = {},
) {
    val coordinator = LocalMonitorDeliveryCoordinator.current ?: return
    val selection = remember(source, files) {
        files?.let { selected -> source.admission(selected)?.let { admission ->
            MonitorOperatorDeliverySelection<R, Unit, Unit, Unit, Unit, Unit>(selected, facts = { source.selection(selected) },
                admission = admission, source = source.source(), photos = photos)
        } }
    }
    MonitorOperatorDeliveryHost(selection, onDismissPopup, coordinator, onPresentationChange)
}

/**
 * One captured selection's delivery inputs. The Host owns the popup, the accepted request and
 * the run; the app supplies its source, typed optional export choices and remote service.
 */
class MonitorOperatorDeliverySelection<R, C, F, P, X, H>(
    val records: List<R>,
    val facts: () -> MonitorDeliverySelectionFacts,
    val admission: MonitorDeliveryAdmission,
    val source: MonitorDeliverySource<R, C, F>,
    val photos: MonitorDeliveryPhotosService<File>?,
    val photosAuthorization: MonitorDeliveryPhotosAuthorizationService? = null,
    val exportOptions: MonitorDeliveryExportOptions<C, F>? = null,
    val configuration: MonitorDeliveryExportConfiguration<C, F>? = null,
    val remote: MonitorOperatorDeliveryRemote<R, P, X, H>? = null,
    val preferredDestination: MonitorDeliveryDestination? = null,
)

/** A remote destination of the popup and the services one accepted upload request runs with. */
class MonitorOperatorDeliveryRemote<R, P, X, H>(
    val service: MonitorDeliveryRemoteService<P, X, H>,
    /** Binds one accepted request (its captured project) to upload services; null refuses it. */
    val run: (MonitorDeliveryPreparedRequest<*, *, P, X, H>) -> MonitorDeliveryRemoteRun<R>?,
)

/** The app-root delivery owner that media hosts below read; null where no app root provides one. */
val LocalMonitorDeliveryCoordinator = staticCompositionLocalOf<MonitorDeliveryCoordinator?> { null }

/** The app-scoped delivery owner; the root closes it before its scope when it leaves. */
@Composable
fun rememberMonitorDeliveryCoordinator(): MonitorDeliveryCoordinator {
    val scope = remember { CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate) }
    val coordinator = remember(scope) { MonitorDeliveryCoordinator(scope) }
    DisposableEffect(coordinator) { onDispose { coordinator.close(); scope.cancel() } }
    return coordinator
}

/**
 * The delivery popup of one selection over the app-scoped [coordinator]. The preparation model
 * is made once per selection; an accepted request starts a run of the coordinator, which
 * continues after this host (and the media screen around it) leaves.
 */
@Composable
fun <R, C, F, P, X, H> MonitorOperatorDeliveryHost(
    selection: MonitorOperatorDeliverySelection<R, C, F, P, X, H>?,
    onDismissPopup: () -> Unit,
    coordinator: MonitorDeliveryCoordinator,
    onPresentationChange: (Boolean) -> Unit = {},
    remoteArtwork: @Composable () -> Unit = { MonitorIcon(MonitorIcon.UPLOAD, null, Modifier.size(18.dp), MonitorPalette.text) },
) {
    val state by coordinator.lifetime.state.collectAsState()
    // Only the popup covers the media screen; a running batch is the root chrome's.
    SideEffect { onPresentationChange(selection != null) }
    val scope = rememberCoroutineScope()
    val preparation = remember(selection) { selection?.preparation(scope, coordinator) }
    if (selection != null && preparation != null) {
        DisposableEffect(preparation) { preparation.start(); onDispose { preparation.close() } }
        MonitorOperatorDeliveryPopupOverlay(preparation, onClose = onDismissPopup, busy = state.running,
            onBegin = { request -> selection.begin(coordinator, request) }, remoteArtwork = remoteArtwork)
    }
}

/**
 * The popup model of this selection. A remote upload from the camera network caches every
 * original as a run of [coordinator] before the hop.
 */
fun <R, C, F, P, X, H> MonitorOperatorDeliverySelection<R, C, F, P, X, H>.preparation(
    scope: CoroutineScope, coordinator: MonitorDeliveryCoordinator,
): MonitorDeliveryPreparationModel<C, F, P, X, H> =
    MonitorDeliveryPreparationModel(scope, observeSelection = facts, configuration = configuration,
        exportOptions = exportOptions, remote = remote?.service, preferredDestination = preferredDestination,
        sourceCurrent = admission::isCurrent,
        beforeInternetHop = remote?.let { remote -> suspend {
            source.load()
            coordinator.cacheBeforeInternetHop(records, source.originals, admission, source.filename,
                remote.service.presentation.progressCaption)
        } })

/** Starts the accepted request as a run of the app-scoped coordinator. */
fun <R, C, F, P, X, H> MonitorOperatorDeliverySelection<R, C, F, P, X, H>.begin(
    coordinator: MonitorDeliveryCoordinator, request: MonitorDeliveryPreparedRequest<C, F, P, X, H>,
): MonitorDeliveryRunHandle? {
    val internet = remote?.service?.internet
    fun release() { request.internetLease?.let { lease -> internet?.restore?.invoke(lease) } }
    val bound = if (request.destination != MonitorDeliveryDestination.REMOTE_UPLOAD) null else {
        remote?.run?.invoke(request) ?: run {
            release(); coordinator.fail("Upload is unavailable."); return null
        }
    }
    // Whatever the destination, the run owns the accepted route lease and restores it at its end.
    return coordinator.begin { admission, progress ->
        coordinator.run(records, request.destination, request.action,
            MonitorDeliveryAdmission { admission.isCurrent() && this.admission.isCurrent() && admission.isCurrent() },
            source, request.configuration, bound, photos, photosAuthorization, internet, request.internetLease, progress)
    } ?: null.also { release() }
}

@Composable
fun <C, F, P, X, H> MonitorOperatorDeliveryPopupOverlay(
    model: MonitorDeliveryPreparationModel<C, F, P, X, H>, onClose: () -> Unit, busy: Boolean = false,
    onBegin: (MonitorDeliveryPreparedRequest<C, F, P, X, H>) -> Unit,
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
            MonitorMediaDeliveryPanel(value = deliveryPanelValue(model, state, busy),
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

/**
 * The panel for [state], the model state the popup collected: reading it in composition is what
 * recomposes the panel when a destination, option or project changes it.
 */
private fun <C, F, P, X, H> deliveryPanelValue(model: MonitorDeliveryPreparationModel<C, F, P, X, H>,
    state: MonitorDeliveryPreparationModel.State<C, F, P, X>, busy: Boolean): MonitorMediaDeliveryValue {
    val serviceName = model.remotePresentation?.displayName ?: "Upload service"; val selection = state.selection; val remote = state.remoteFacts; val config = state.configuration; val options = model.clipExportOptions
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
            reupload = if (model.offersReupload) MonitorMediaDeliveryValue.Toggle("Re-upload already uploaded", "Skip clips already on $serviceName unless enabled.", config.forceReupload) else null)
    } else if (!model.internetGate && state.step == MonitorDeliveryPreparationModel.Step.OPTIONS && selection.files.size == 1) MonitorMediaDeliveryValue.Export(filename = selection.files.first().filename) else null
    return MonitorMediaDeliveryValue(if (state.step == MonitorDeliveryPreparationModel.Step.DESTINATION) MonitorMediaDeliveryValue.Step.DESTINATION else MonitorMediaDeliveryValue.Step.OPTIONS,
        title = state.destination?.title(model.remotePresentation?.displayName) ?: "Share", selectionLabel = "${selection.files.size} clip${if (selection.files.size == 1) "" else "s"}", notices = notices,
        destinations = listOfNotNull(MonitorMediaDeliveryValue.Destination(MonitorDeliveryDestination.NATIVE_SHARE.name, "Share", "Nearby Share, Files, and other apps", model.destinationEnabled(MonitorDeliveryDestination.NATIVE_SHARE)),
            if (remote != null) MonitorMediaDeliveryValue.Destination(MonitorDeliveryDestination.REMOTE_UPLOAD.name, MonitorDeliveryDestination.REMOTE_UPLOAD.title(model.remotePresentation?.displayName), MonitorDeliveryDestination.REMOTE_UPLOAD.subtitle(model.remotePresentation?.displayName), model.destinationEnabled(MonitorDeliveryDestination.REMOTE_UPLOAD)) else null),
        upcoming = MediaDeliveryUpcoming.titles, service = service, export = export,
        footer = if (state.step == MonitorDeliveryPreparationModel.Step.OPTIONS && !model.internetGate) MonitorMediaDeliveryValue.Footer(
            summary = config?.let { deliverySummary(selection, it, options) },
            postExport = if (state.destination == MonitorDeliveryDestination.NATIVE_SHARE) MonitorMediaDeliveryValue.Choices("", options = listOf(
                MonitorMediaDeliveryValue.Choice(MonitorDeliveryPostExportAction.SYSTEM_SHARE.name, "Share"), MonitorMediaDeliveryValue.Choice(MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS.name, "Save to Photos")), selectedID = state.action.name) else null,
            actionTitle = if (state.destination == MonitorDeliveryDestination.REMOTE_UPLOAD) "Upload" else if (state.action == MonitorDeliveryPostExportAction.SAVE_TO_PHOTOS) "Save to Photos" else "Share", enabled = model.canContinue && !busy) else null)
}

/**
 * The options footer's line: clip count, total size and what is delivered
 * (Swift `MonitorOperatorDeliveryScreen.summary`).
 */
internal fun <C, F> deliverySummary(selection: MonitorDeliverySelectionFacts, config: MonitorDeliveryExportConfiguration<C, F>,
    options: MonitorDeliveryExportOptions<C, F>?): String {
    val files = selection.files
    val known = files.mapNotNull { it.sizeBytes }
    val bytes = known.fold(0L) { total, value -> if (value > Long.MAX_VALUE - total) Long.MAX_VALUE else total + value }
    val size = if (bytes == 0L) "0 B" else MediaClipFormatting.byteLabel(bytes)
    val label = if (known.isEmpty()) "Size unavailable" else if (known.size == files.size) size else "At least $size"
    val mode = if (config.convertLog) options?.curves?.firstOrNull { it.value == config.logTransform }?.label ?: "Converted log"
        else if (config.bakeLUT) "LUT baked" else "Camera original"
    return "${files.size} ${if (files.size == 1) "clip" else "clips"} · $label · $mode"
}

/** What the delivery chrome shows for one progress value. */
data class MonitorOperatorDeliveryFacts(
    val value: MonitorMediaDeliveryProgressValue, val destination: MonitorDeliveryDestination,
    val details: MonitorMediaDeliveryProgressDetailsValue = MonitorMediaDeliveryProgressDetailsValue(),
)

fun MonitorDeliveryBatchProgress.chromeFacts(remoteDisplayName: String?): MonitorOperatorDeliveryFacts =
    MonitorOperatorDeliveryFacts(
        MonitorMediaDeliveryProgressValue(statusLine(), if (totalClips > 1) "Clip ${minOf(clipIndex, totalClips)} of $totalClips" else null,
            overallFraction, preparing = showsBusySpinner, showsProgress = !isPreparingClip),
        destination, MonitorMediaDeliveryProgressDetailsValue(filename, destination.title(remoteDisplayName)))

/**
 * One delivery chrome for every app (A4-10): compact progress with cancel, an expandable detail
 * panel, the outcome toast and the share chooser of a finished run, all read from the
 * app-scoped coordinator. Mount it once, as the last child of the app root, so it stays above
 * every screen and survives leaving the gallery or the player.
 */
@Composable
fun MonitorOperatorDeliveryChrome(
    coordinator: MonitorDeliveryCoordinator, share: MediaShare, mimeType: (java.io.File) -> String,
    modifier: Modifier = Modifier, remoteDisplayName: String? = null,
    displayName: (java.io.File) -> String = { it.name },
) {
    val delivery = coordinator.lifetime
    val state by delivery.state.collectAsState()
    val context = LocalContext.current
    var presenting by remember(delivery) { mutableStateOf<java.util.UUID?>(null) }
    val chooser = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        presenting?.let(delivery::completeSharePresentation); presenting = null
    }
    LaunchedEffect(state.share?.id) {
        val ready = state.share ?: return@LaunchedEffect
        if (presenting != null) return@LaunchedEffect
        val intent = withContext(Dispatchers.IO) {
            share.chooserIntent(context, ready.payload.urls, mimeType, ready.payload.metadataText, displayName)
        }
        val launched = intent != null && runCatching { presenting = ready.id; chooser.launch(intent) }.isSuccess
        if (!launched) {
            presenting = null; delivery.clearSharePresentation(ready.id)
            coordinator.fail(if (ready.payload.urls.size == 1) "Couldn't share this clip." else "Couldn't share these clips.")
        }
    }
    Box(modifier.fillMaxSize()) {
        state.progress?.let { progress ->
            val facts = progress.chromeFacts(remoteDisplayName)
            val icon: @Composable () -> Unit = {
                MonitorIcon(if (facts.destination == MonitorDeliveryDestination.NATIVE_SHARE) MonitorIcon.SHARE else MonitorIcon.UPLOAD,
                    null, Modifier.size(13.dp), MonitorPalette.accent)
            }
            val placement = Modifier.align(Alignment.TopCenter).statusBarsPadding()
                .padding(horizontal = 20.dp, vertical = 8.dp).widthIn(max = 420.dp)
            if (state.expanded) MonitorMediaDeliveryProgressPanel(facts.value, facts.details, delivery::cancel,
                { delivery.setExpanded(false) }, placement, icon)
            else MonitorMediaDeliveryProgress(facts.value, delivery::cancel, placement, { delivery.setExpanded(true) }, icon)
        }
        state.toast?.let { message ->
            Text(message, style = MonitorTypography.text(13f, FontWeight.Medium), color = MonitorPalette.text,
                modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 28.dp)
                    .clip(MediaCapsuleShape).background(MonitorPalette.surface, MediaCapsuleShape)
                    .border(1.dp, Color.White.copy(alpha = .10f), MediaCapsuleShape)
                    .padding(horizontal = 16.dp, vertical = 10.dp))
        }
    }
}

/** Listed on the Share sheet; never selectable and never starts auth or upload. */
object MediaDeliveryUpcoming {
    val titles = listOf("Google Drive", "Dropbox", "NAS (SMB)", "LucidLink", "Backblaze B2", "Vimeo Review")
}
