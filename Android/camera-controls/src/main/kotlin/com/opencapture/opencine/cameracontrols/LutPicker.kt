package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.LocalOperatorHaptics
import com.opencapture.monitorui.MonitorLabelWheel
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.monitorTabStrip
import com.opencapture.monitorui.monitorScrollFade
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.opencine.vocabulary.CameraCommands
import com.opencapture.opencine.vocabulary.CameraLUTProfile
import com.opencapture.opencine.vocabulary.LutCatalog
import com.opencapture.opencine.vocabulary.LutCategory
import com.opencapture.opencine.vocabulary.LutEntry
import com.opencapture.opencine.vocabulary.LutLookResolver
import com.opencapture.opencine.media.MonitorLUTExposureCompensation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * What one app's LUT picker says about its camera tab; the catalog, captions logic and layout are
 * shared. [autoId] is the Auto entry the camera tab falls back to.
 */
data class LutPickerCopy(
    val cameraTab: String,
    val autoId: String,
    val customHint: String,
    /** Auto applies no cube. */
    val noLookCaption: String,
    /** An official cube is selected. */
    val officialCubeCaption: String,
    /** Anything else on the camera tab. */
    val cameraLooksCaption: String,
)

/** One look in a [LutPickerLibrary]; [title] is what its drum or file row shows. */
data class LutPickerEntry(val id: String, val title: String)

/** A drum of looks, or the imported-file list under an import button. */
enum class LutPickerLayout { DRUM, FILES }

/** A choice row in the caption slot that narrows the drum (RED's output colour space on Z). */
data class LutPickerFilter(val options: List<String>, val selected: String, val onSelect: (String) -> Unit)

/** A button under an empty library (a vendor download). */
data class LutPickerAction(val title: String, val onClick: () -> Unit)

/** What an empty library shows: why it is empty and, optionally, how to fill it. */
data class LutPickerEmpty(val title: String? = null, val hint: String, val action: LutPickerAction? = null)

/**
 * One tab of the shared LUT picker (iOS `LUTPickerLibrary`), supplied by the app as a value: its
 * official looks, a library the operator downloaded from a vendor (RED's IPP2 presets on Z) or
 * imported cubes. [isCurrent] opens the picker on this tab; [representative] is the look a switch
 * to this tab applies while another tab's look is current, and the drum's resting row.
 */
data class LutPickerLibrary(
    val title: String,
    val entries: List<LutPickerEntry>,
    val isCurrent: Boolean,
    val selectedId: String?,
    val onSelect: (LutPickerEntry) -> Unit,
    val layout: LutPickerLayout = LutPickerLayout.DRUM,
    val representative: LutPickerEntry? = null,
    val caption: String = "",
    val filter: LutPickerFilter? = null,
    /** Looks flagged with a star (a recommended default). */
    val markedIds: Set<String> = emptySet(),
    val empty: LutPickerEmpty? = null,
    /** Removes a stored look once the picker has confirmed; the app reports a failure. */
    val onDelete: ((LutPickerEntry) -> Unit)? = null,
    /** Opens the app's document picker for a `.cube`. */
    val onImport: (() -> Unit)? = null,
) {
    /** The drum row: the applied look, else the representative, else the first look. */
    val drumId: String?
        get() = selectedId?.takeIf { id -> entries.any { it.id == id } }
            ?: representative?.id ?: entries.firstOrNull()?.id

    fun label(entry: LutPickerEntry): String = if (entry.id in markedIds) "★ ${entry.title}" else entry.title
}

/** Camera / Creative / Custom over one app's camera looks, as the shared picker's libraries. */
internal fun lutPickerLibraries(
    copy: LutPickerCopy,
    selection: String,
    cameraEntries: List<LutEntry>,
    creativeEntries: List<LutEntry>,
    customEntries: List<LutEntry>,
    colorMode: Int,
    profile: CameraLUTProfile?,
    isPhoto: Boolean,
    onPick: (String) -> Unit,
    onImport: () -> Unit,
    onClear: (LutEntry) -> Unit,
): List<LutPickerLibrary> {
    val category = LutCatalog.categoryOf(selection)
    fun entry(look: LutEntry) = LutPickerEntry(look.id, look.title)
    fun selected(entries: List<LutEntry>) = entries.firstOrNull { LutCatalog.matches(it, selection) }?.id
    fun representative(entries: List<LutEntry>, id: String) =
        LutPickerEntry(id, entries.firstOrNull { it.id == id }?.title ?: id)
    val pick: (LutPickerEntry) -> Unit = { onPick(it.id) }
    return listOf(
        LutPickerLibrary(
            title = copy.cameraTab, entries = cameraEntries.map(::entry),
            isCurrent = category == LutCategory.CAMERA, selectedId = selected(cameraEntries),
            onSelect = pick, representative = representative(cameraEntries, copy.autoId),
            caption = cameraCaption(copy, selection, colorMode, profile, isPhoto),
        ),
        LutPickerLibrary(
            title = "Creative", entries = creativeEntries.map(::entry),
            isCurrent = category == LutCategory.CREATIVE, selectedId = selected(creativeEntries),
            onSelect = pick, representative = representative(creativeEntries, "creativeMono"),
            caption = creativeCaption(copy, selection, colorMode, profile, isPhoto),
        ),
        LutPickerLibrary(
            title = "Custom", entries = customEntries.map(::entry), layout = LutPickerLayout.FILES,
            isCurrent = category == LutCategory.CUSTOM, selectedId = selected(customEntries),
            onSelect = pick, empty = LutPickerEmpty(hint = copy.customHint), onImport = onImport,
            onDelete = { look -> customEntries.firstOrNull { it.id == look.id }?.let(onClear) },
        ),
    )
}

/** iOS `LUTPicker` landscape metrics: caption + drum, not a stretched well.
 * Catalog is ~15% taller than iOS 146 so the fade well can show neighbours. */
internal object LutPickerMetrics {
    const val CONTENT_DP = 168f
    const val CAPTION_DP = 28f
    const val ROW_DP = 52f
    const val WHEEL_GAP_DP = 4f
    const val SPLIT_TYPE_PT = 11f
    const val SPLIT_ICON_DP = 13f
    const val SPLIT_PAD_H_DP = 10f
    const val SPLIT_PAD_V_DP = 6f
    const val CLOSE_DP = 27f
}

private val LutContentHeight = LutPickerMetrics.CONTENT_DP.dp
private val LutCaptionHeight = LutPickerMetrics.CAPTION_DP.dp
private val LutDrumRowHeight = LutPickerMetrics.ROW_DP.dp

/**
 * Camera / Creative / Custom catalog with an AccentDrumWheel (iOS `LUTPicker`).
 * `embedded` is the assist-tray form; the sheet wraps the same body.
 */
@Composable
fun LUTPicker(
    copy: LutPickerCopy,
    selection: String,
    onSelect: (String) -> Unit,
    library: MonitorLutLibrary,
    embedded: Boolean,
    splitComparison: Boolean,
    splitVertical: Boolean,
    lutExposureStops: Double = 0.0,
    onToggleSplit: () -> Unit,
    onSplitVertical: (Boolean) -> Unit,
    onExposure: (Double) -> Unit = {},
    onArmLut: () -> Unit = {},
    onClose: (() -> Unit)? = null,
    colorMode: Int = CameraCommands.COLOR_NORMAL,
    profile: CameraLUTProfile? = null,
    isPhoto: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val cameraEntries =
        remember(context, isPhoto, profile) {
            val names = context.assets.list(LutCatalog.ASSET_DIRECTORY)?.toList().orEmpty()
            if (profile?.cameraLooks.isNullOrEmpty()) LutCatalog.officialEntries(names, isPhotoLive = isPhoto)
            else if (isPhoto) listOf(LutCatalog.auto) else LutCatalog.cameraEntries(names, looks = profile?.cameraLooks.orEmpty())
        }
    val creativeEntries = remember { LutCatalog.creative }
    var deletionError by remember { mutableStateOf<String?>(null) }
    var importError by remember { mutableStateOf<String?>(null) }
    val storedEntries by library.entries.collectAsState()
    val customEntries = remember(storedEntries) {
        LutCatalog.storedCustom(storedEntries.filter { it.selection.category == MonitorLutCategory.CUSTOM }
            .map { it.selection.fileName })
    }
    val scope = rememberCoroutineScope()
    // Keep this picker's import/delete requests ordered while document IO and packing suspend.
    val mutations = remember(library) { Mutex() }
    val currentSelection by rememberUpdatedState(selection)
    val selectCurrent by rememberUpdatedState(onSelect)
    val armCurrent by rememberUpdatedState(onArmLut)
    val importer =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri == null) return@rememberLauncherForActivityResult
            scope.launch {
                mutations.withLock {
                    val result = try {
                        library.importDocument(context.contentResolver, uri)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Exception) {
                        MonitorLutImportResult.Rejected(error.message ?: "The .cube file could not be read.")
                    }
                    when (result) {
                        is MonitorLutImportResult.Imported -> {
                            importError = null
                            if (currentSelection != LutCatalog.AUTO && currentSelection != LutCatalog.OFFICIAL_AUTO) {
                                selectCurrent(LutCatalog.customId(result.entry.selection.fileName))
                            }
                            armCurrent()
                        }
                        is MonitorLutImportResult.Rejected -> importError = result.message
                    }
                }
            }
        }
    val libraries =
        lutPickerLibraries(
            copy, selection, cameraEntries, creativeEntries, customEntries, colorMode, profile, isPhoto,
            onPick = { id ->
                onSelect(id)
                onArmLut()
            },
            onImport = { importer.launch(arrayOf("*/*")) },
            onClear = { look ->
                val fileName = look.fileName ?: return@lutPickerLibraries
                val target = MonitorLutSelection.of(MonitorLutCategory.CUSTOM, fileName) ?: return@lutPickerLibraries
                scope.launch {
                    mutations.withLock {
                        try {
                            if (library.delete(target)) {
                                if (currentSelection == LutCatalog.customId(fileName)) {
                                    selectCurrent(LutCatalog.AUTO)
                                    armCurrent()
                                }
                            } else {
                                deletionError = "The LUT \u201c${LutCatalog.displayName(fileName)}\u201d could not be deleted."
                            }
                        } catch (cancelled: CancellationException) {
                            throw cancelled
                        } catch (error: Exception) {
                            deletionError = error.message ?: "The LUT could not be deleted."
                        }
                    }
                }
            },
        )
    val footer: (@Composable () -> Unit)? =
        if (embedded) null else {
            {
                LUTSplitComparisonBar(
                    splitComparison = splitComparison,
                    splitVertical = splitVertical,
                    lutExposureStops = lutExposureStops.takeIf { lutExposureOffered(colorMode) },
                    onToggleSplit = onToggleSplit,
                    onSplitVertical = onSplitVertical,
                    onExposure = onExposure,
                )
            }
        }

    if (embedded) {
        LUTPicker(libraries, modifier, embedded = true, message = importError)
    } else {
        BackHandler(enabled = onClose != null, onBack = { onClose?.invoke() })
        Column(
            Modifier.fillMaxSize()
                .background(LiveDesign.background)
                .statusBarsPadding()
                .navigationBarsPadding()
                .padding(20.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("LUT", color = LiveDesign.text, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                if (onClose != null) {
                    Text(
                        "Done",
                        color = LiveDesign.accent,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier =
                            Modifier.chromeClickable(onClick = onClose)
                                .padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            LUTPicker(libraries, modifier, embedded = false, footer = footer, message = importError)
        }
    }

    if (deletionError != null) {
        AlertDialog(
            onDismissRequest = { deletionError = null },
            title = { Text("Couldn’t Delete LUT") },
            text = { Text(deletionError ?: "The LUT could not be deleted.") },
            confirmButton = { TextButton(onClick = { deletionError = null }) { Text("OK") } },
        )
    }
}

/**
 * The shared LUT picker over an app's libraries (iOS `LUTPickerView`): the tabs, the open tab's
 * drum or file list, then [footer] (the sheet's comparison) and [message] (an import error). A
 * stored look's delete is confirmed here before the library's [LutPickerLibrary.onDelete] runs.
 */
@Composable
fun LUTPicker(
    libraries: List<LutPickerLibrary>,
    modifier: Modifier = Modifier,
    embedded: Boolean = true,
    footer: (@Composable () -> Unit)? = null,
    message: String? = null,
) {
    var tab by remember { mutableStateOf((libraries.firstOrNull { it.isCurrent } ?: libraries.firstOrNull())?.title) }
    var pendingDeletion by remember { mutableStateOf<Pair<String, LutPickerEntry>?>(null) }
    val open = libraries.firstOrNull { it.title == tab } ?: libraries.firstOrNull { it.isCurrent } ?: libraries.firstOrNull()
    val haptics = LocalOperatorHaptics.current
    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .then(if (embedded) Modifier.fillMaxHeight() else Modifier),
    ) {
        val tabBlock = 44.dp
        val tabGap = 8.dp
        val contentH =
            if (constraints.hasBoundedHeight) {
                (maxHeight - tabBlock - tabGap).coerceAtLeast(LutDrumRowHeight)
            } else {
                LutContentHeight
            }
        val boundedSheet = !embedded && constraints.hasBoundedHeight
        Column(
            Modifier.fillMaxWidth().then(
                if (boundedSheet) Modifier.fillMaxHeight() else Modifier.wrapContentHeight()),
            verticalArrangement = Arrangement.spacedBy(tabGap),
        ) {
            Row(Modifier.fillMaxWidth().monitorTabStrip()) {
                libraries.forEachIndexed { index, library ->
                    val selected = library.title == open?.title
                    MonitorTab(selected, {
                        haptics.selection()
                        if (!selected) {
                            tab = library.title
                            if (!library.isCurrent) library.representative?.let(library.onSelect)
                        }
                    }, Modifier.weight(1f).testTag("monitor.lut.tab.${library.title}"),
                        separator = index > 0, accessibilityLabel = library.title) {
                        Text(library.title, style = LiveType.ui(13f, FontWeight.SemiBold),
                            color = if (selected) LiveDesign.accent else LiveDesign.muted, maxLines = 1)
                    }
                }
            }
            // Column measures the actual footer/message first, then gives the catalog the rest.
            BoxWithConstraints(Modifier.fillMaxWidth().then(
                if (boundedSheet) Modifier.weight(1f) else Modifier.height(contentH)
            ).then(if (boundedSheet) Modifier.clipToBounds() else Modifier)) {
                val visibleCatalogHeight = if (boundedSheet) maxHeight else contentH
                val catalogHeight = visibleCatalogHeight.coerceAtLeast(LutDrumRowHeight)
                val overflow = boundedSheet && catalogHeight > visibleCatalogHeight
                Box(Modifier.fillMaxSize().then(
                    if (overflow) Modifier.verticalScroll(rememberScrollState()) else Modifier
                )) {
                    Box(Modifier.fillMaxWidth().height(catalogHeight)) {
                        if (open != null) {
                            key(open.title) {
                                when (open.layout) {
                                    LutPickerLayout.DRUM ->
                                        DrumTab(open, catalogHeight) { pendingDeletion = open.title to it }
                                    LutPickerLayout.FILES ->
                                        FilesTab(open) { pendingDeletion = open.title to it }
                                }
                            }
                        }
                    }
                }
            }
            footer?.invoke()
            if (message != null) {
                Text(message, color = LiveDesign.destructive, fontSize = 12.sp)
            }
        }
    }

    pendingDeletion?.let { (library, look) ->
        AlertDialog(
            onDismissRequest = { pendingDeletion = null },
            title = { Text("Clear ${look.title}?") },
            text = { Text("This removes the stored LUT from this device. This action cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDeletion = null
                        libraries.firstOrNull { it.title == library }?.onDelete?.invoke(look)
                    }
                ) { Text("Clear LUT", color = LiveDesign.destructive) }
            },
            dismissButton = { TextButton(onClick = { pendingDeletion = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun DrumTab(library: LutPickerLibrary, contentHeight: Dp, onDelete: (LutPickerEntry) -> Unit) {
    val empty = library.empty
    if (library.entries.isEmpty() && library.filter == null && empty != null) {
        Column(
            Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterVertically),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            empty.title?.let {
                Text(it, color = LiveDesign.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
            Text(empty.hint, color = LiveDesign.muted, fontSize = 12.sp, textAlign = TextAlign.Center)
            empty.action?.let { action ->
                Box(
                    Modifier.fillMaxWidth()
                        .clip(RoundedCornerShape(50))
                        .background(LiveDesign.glassBright)
                        .chromeClickable(onClick = action.onClick)
                        .padding(vertical = 12.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(action.title, color = LiveDesign.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                }
            }
        }
        return
    }
    val gap = LutPickerMetrics.WHEEL_GAP_DP.dp
    val captionH = if (contentHeight >= LutContentHeight) LutCaptionHeight else 18.dp
    val minCaptioned = captionH + LutDrumRowHeight
    val showCaption = contentHeight >= minCaptioned
    val captionGap = if (showCaption && contentHeight >= minCaptioned + gap) gap else 0.dp
    val drumH =
        if (showCaption) {
            (contentHeight - captionH - captionGap).coerceAtLeast(LutDrumRowHeight)
        } else {
            contentHeight.coerceAtLeast(LutDrumRowHeight)
        }
    Column(
        Modifier.fillMaxWidth().height(contentHeight),
        verticalArrangement = Arrangement.spacedBy(captionGap),
    ) {
        if (showCaption) {
            Box(
                Modifier.fillMaxWidth().height(captionH),
                contentAlignment = Alignment.Center,
            ) {
                val filter = library.filter
                if (filter != null) {
                    LutFilterRow(filter)
                } else {
                    Text(
                        library.caption,
                        style = LiveType.ui(11f, FontWeight.Medium),
                        color = LiveDesign.muted,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
        val haptics = LocalOperatorHaptics.current
        MonitorLabelWheel(
            entries = library.entries,
            selection = library.drumId.orEmpty(),
            matches = { entry, id -> entry.id == id },
            key = { it.id },
            label = library::label,
            onSelect = library.onSelect,
            rowHeight = LutDrumRowHeight,
            wheelHeight = drumH,
            onClickFeedback = { haptics.selection() },
            onLongPress = if (library.onDelete != null) onDelete else null,
        )
    }
}

@Composable
private fun LutFilterRow(filter: LutPickerFilter) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally)) {
        filter.options.forEach { option ->
            val on = option == filter.selected
            Box(
                Modifier.clip(RoundedCornerShape(50))
                    .background(if (on) LiveDesign.accentDim else LiveDesign.glassBright)
                    .chromeClickable { filter.onSelect(option) }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            ) {
                Text(option, style = LiveType.ui(12f, FontWeight.SemiBold),
                    color = if (on) LiveDesign.accent else LiveDesign.muted, maxLines = 1)
            }
        }
    }
}

@Composable
private fun FilesTab(library: LutPickerLibrary, onDelete: (LutPickerEntry) -> Unit) {
    Column(Modifier.fillMaxSize()) {
        library.onImport?.let { onImport ->
            Box(
                Modifier.fillMaxWidth()
                    .clip(RoundedCornerShape(50))
                    .background(LiveDesign.glassBright)
                    .clickable(onClick = onImport)
                    .padding(vertical = 8.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("Import .cube", color = LiveDesign.text, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.height(6.dp))
        }
        if (library.entries.isEmpty()) {
            Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                Text(
                    library.empty?.hint.orEmpty(),
                    color = LiveDesign.muted,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
        } else {
            val importedScroll = rememberScrollState()
            Column(Modifier.weight(1f).fillMaxWidth().monitorScrollFade(importedScroll).verticalScroll(importedScroll)) {
                library.entries.forEach { entry ->
                    val selected = entry.id == library.selectedId
                    Row(
                        Modifier.fillMaxWidth()
                            .clip(RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp))
                            .background(if (selected) LiveDesign.accentDim else LiveDesign.glassBright)
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            entry.title,
                            color = if (selected) LiveDesign.accent else LiveDesign.text,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier =
                                Modifier.weight(1f)
                                    .clickable { library.onSelect(entry) }
                                    .padding(vertical = 6.dp),
                        )
                        if (library.onDelete != null) {
                            Box(
                                Modifier.clip(RoundedCornerShape(50))
                                    .background(LiveDesign.glassBright)
                                    .clickable { onDelete(entry) }
                                    .padding(horizontal = 8.dp, vertical = 6.dp),
                            ) {
                                Text("Clear", color = LiveDesign.destructive, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                            }
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                }
            }
        }
    }
}

/** Absolute half-stop slider over the existing input-referred LUT compensation. */
@Composable
fun LUTExposureCompensationBar(stops: Double, onChange: (Double) -> Unit,
    modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("Exposure", style = LiveType.ui(11f, FontWeight.Medium), color = LiveDesign.text)
            Spacer(Modifier.weight(1f))
            Text(MonitorLUTExposureCompensation.label(stops) + " EV", style = LiveType.ui(11f, FontWeight.Medium),
                color = LiveDesign.muted)
        }
        com.opencapture.monitorui.MonitorSlider(stops.toFloat(), -3f..3f,
            Modifier.semantics { contentDescription = "Exposure compensation in stops" }) {
            val next = MonitorLUTExposureCompensation.snap(it.toDouble())
            if (next != stops) onChange(next)
        }
    }
}

/** 50/50 split: off by default; orientation chips only while armed. */
@Composable
fun LUTSplitComparisonBar(
    splitComparison: Boolean,
    splitVertical: Boolean,
    lutExposureStops: Double? = 0.0,
    onToggleSplit: () -> Unit,
    onSplitVertical: (Boolean) -> Unit,
    onExposure: (Double) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        lutExposureStops?.let { LUTExposureCompensationBar(stops = it, onChange = onExposure) }
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Split comparison", style = LiveType.ui(11f, FontWeight.Medium), color = LiveDesign.text)
            Spacer(Modifier.weight(1f))
            Row(
                Modifier.clip(RoundedCornerShape(50))
                    .background(if (splitComparison) LiveDesign.accentDim else LiveDesign.glassBright)
                    .chromeClickable(onClick = onToggleSplit)
                    .padding(
                        horizontal = LutPickerMetrics.SPLIT_PAD_H_DP.dp,
                        vertical = LutPickerMetrics.SPLIT_PAD_V_DP.dp,
                    ),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                MonitorIcon(
                    icon = if (splitComparison) MonitorIcon.CIRCLE_CHECK else MonitorIcon.CIRCLE,
                    contentDescription = null,
                    tint = if (splitComparison) LiveDesign.accent else LiveDesign.muted,
                    modifier = Modifier.size(LutPickerMetrics.SPLIT_ICON_DP.dp),
                )
                Text(
                    "50/50",
                    style = LiveType.ui(LutPickerMetrics.SPLIT_TYPE_PT, FontWeight.SemiBold),
                    color = LiveDesign.text,
                )
            }
        }
        if (splitComparison) {
            LutSegmentedButtons(
                items = listOf("Left / Right", "Top / Bottom"),
                selected = if (splitVertical) "Left / Right" else "Top / Bottom",
            ) { label ->
                onSplitVertical(label == "Left / Right")
            }
        }
    }
}

@Composable
private fun LutSegmentedButtons(
    items: List<String>,
    selected: String,
    modifier: Modifier = Modifier,
    onSelect: (String) -> Unit,
) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        items.forEach { item ->
            val on = item == selected
            Box(
                Modifier.weight(1f)
                    .clip(RoundedCornerShape(50))
                    .background(if (on) LiveDesign.accent else LiveDesign.glassBright)
                    .chromeClickable { onSelect(item) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    item,
                    style = LiveType.ui(13f, FontWeight.SemiBold),
                    color = if (on) Color(0xFF08191F) else LiveDesign.muted,
                    maxLines = 1,
                )
            }
        }
    }
}

internal fun creativeCaption(
    copy: LutPickerCopy,
    selection: String,
    colorMode: Int,
    profile: CameraLUTProfile?,
    isPhoto: Boolean,
): String =
    if (LutCatalog.categoryOf(selection) == LutCategory.CREATIVE) {
        LutLookResolver.autoCaption(
            LutLookResolver.resolve(selection, true, colorMode, profile, isPhoto),
            copy.noLookCaption, profile?.cameraLooks.orEmpty(),
        )
    } else {
        "Looks for the displayed picture"
    }

internal fun cameraCaption(
    copy: LutPickerCopy,
    selection: String,
    colorMode: Int,
    profile: CameraLUTProfile?,
    isPhoto: Boolean,
): String =
    if (isPhoto) {
        LutCatalog.PHOTO_REC709_CAPTION
    } else when {
        selection == LutCatalog.AUTO || selection == LutCatalog.OFFICIAL_AUTO ->
            LutLookResolver.autoCaption(
                LutLookResolver.resolve(selection, true, colorMode, profile, isPhoto),
                copy.noLookCaption, profile?.cameraLooks.orEmpty(),
            )
        selection.startsWith("camera:") ->
            profile?.cameraLooks?.firstOrNull { it.id == selection }?.caption ?: "Manual camera conversion"
        LutCatalog.categoryOf(selection) == LutCategory.CAMERA -> copy.officialCubeCaption
        else -> copy.cameraLooksCaption
    }
