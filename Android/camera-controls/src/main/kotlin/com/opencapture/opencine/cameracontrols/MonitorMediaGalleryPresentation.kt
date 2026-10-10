package com.opencapture.opencine.cameracontrols

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.Role
import com.opencapture.monitorui.MonitorMediaNavigation
import com.opencapture.monitorui.MonitorMediaNavigationCategory
import com.opencapture.monitorui.MonitorCatalogDisplayControls
import com.opencapture.monitorui.MonitorMediaLayout as DisplayLayout
import com.opencapture.monitorui.MonitorThumbnailSize as DisplayThumbnailSize
import com.opencapture.monitorui.MonitorMediaFilterChoice
import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.monitorui.MonitorThumbnailSize
import com.opencapture.opencine.media.MonitorMediaProjectionResult
import com.opencapture.opencine.vocabulary.MediaLibrarySort
import com.opencapture.opencine.vocabulary.MediaLibraryTab

public sealed interface MonitorMediaGalleryNavigation {
    public data class Category(public val value: MediaLibraryTab) : MonitorMediaGalleryNavigation
    public data class Layout(public val value: MonitorMediaLayout) : MonitorMediaGalleryNavigation
    public data class ThumbnailSize(public val value: MonitorThumbnailSize) : MonitorMediaGalleryNavigation
    public data object CycleSort : MonitorMediaGalleryNavigation
}
public sealed interface MonitorMediaGalleryFilterAction {
    public data class Format(public val id: String) : MonitorMediaGalleryFilterAction
    public data class Resolution(public val id: String) : MonitorMediaGalleryFilterAction
    public data class PhotoSize(public val id: String) : MonitorMediaGalleryFilterAction
    public data class DateWindow(public val id: String) : MonitorMediaGalleryFilterAction
    public data class Storage(public val id: String) : MonitorMediaGalleryFilterAction
    public data object Reset : MonitorMediaGalleryFilterAction
}
public data class MonitorMediaGalleryFilters(
    public val formats: List<String>, public val resolutions: List<String>,
    public val photoSizes: List<MonitorMediaFilterChoice> = emptyList(),
    public val dateWindows: List<MonitorMediaFilterChoice> = emptyList(),
    public val storage: List<MonitorMediaFilterChoice> = emptyList(),
    public val formatSelection: Set<String>, public val resolutionSelection: Set<String>,
    public val photoSizeSelection: Set<String> = emptySet(),
    public val dateWindow: String? = null, public val storageID: String? = null,
    public val dialog: Boolean = false,
)
public data class MonitorMediaGalleryStorage(public val id: String, public val title: String,
    public val summary: String, public val selected: Boolean, public val description: String? = null)
public data class MonitorMediaGalleryEmpty(public val title: String, public val detail: String,
    public val loading: Boolean = false, public val retry: Boolean = false)
public data class MonitorMediaGalleryCellContext(public val list: Boolean, public val selecting: Boolean,
    public val selected: Boolean, public val duration: String?)
/** Immutable domain projection and persisted display facts; no task/page/native ownership. */
public data class MonitorMediaGalleryPresentation(
    public val projection: MonitorMediaProjectionResult,
    public val category: MediaLibraryTab, public val layout: MonitorMediaLayout,
    public val thumbnailSize: MonitorThumbnailSize, public val sort: MediaLibrarySort,
    public val activeFilterCount: Int, public val filters: MonitorMediaGalleryFilters,
    public val storage: List<MonitorMediaGalleryStorage> = emptyList(),
    public val navigationClearsSelection: Boolean = false, public val filterClearsSelection: Boolean = false,
    public val retainsVisibleSelection: Boolean = false,
    public val empty: MonitorMediaGalleryEmpty? = null,
)

@Composable
public fun MonitorMediaGalleryStorageCards(values: List<MonitorMediaGalleryStorage>, select: (String) -> Unit,
    horizontal: Boolean = false, modifier: Modifier = Modifier): Unit {
    val cards: @Composable () -> Unit = {
        values.forEach { value ->
            val shape = RoundedCornerShape(8.dp)
            Column(Modifier.then(if (horizontal) Modifier.width(154.dp) else Modifier.fillMaxWidth())
                .heightIn(min = 48.dp).background(if (value.selected) LiveDesign.accentDim else LiveDesign.surface, shape)
                .border(1.dp, if (value.selected) LiveDesign.accent.copy(alpha = 0.5f) else LiveDesign.hairline, shape)
                .semantics { contentDescription = value.description ?: "${value.title}, ${value.summary}"
                    role = Role.RadioButton; selected = value.selected }
                .chromeClickable(onClick = { select(value.id) }).padding(horizontal = 10.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(value.title, color = if (value.selected) LiveDesign.accent else LiveDesign.text,
                    style = LiveType.ui(11f, FontWeight.SemiBold), maxLines = 1)
                Text(value.summary, color = LiveDesign.muted, style = LiveType.ui(9f, FontWeight.Medium), maxLines = if (horizontal) 1 else 2)
            }
        }
    }
    if (horizontal) Row(modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(8.dp)) { cards() }
    else Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) { cards() }
}

/** The exercised landscape navigation owner, also used by compatibility entry points. */
@Composable
public fun MonitorMediaGalleryNavigationRail(category: MediaLibraryTab,
    storage: List<MonitorMediaGalleryStorage>, selectCategory: (MediaLibraryTab) -> Unit,
    selectStorage: (String) -> Unit, layout: DisplayLayout, thumbnailSize: DisplayThumbnailSize,
    selectLayout: (DisplayLayout) -> Unit, selectThumbnailSize: (DisplayThumbnailSize) -> Unit,
    showsDisplayControls: Boolean = true, modifier: Modifier = Modifier): Unit {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(Modifier.weight(1f, fill = false).fillMaxWidth().verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            MonitorMediaNavigation(categories = MediaLibraryTab.entries.map {
                MonitorMediaNavigationCategory(it.name, it.name.lowercase().replaceFirstChar { first -> first.titlecase() }) },
                selectedID = category.name, vertical = true,
                onSelect = { id -> MediaLibraryTab.entries.firstOrNull { it.name == id }?.let(selectCategory) })
            MonitorMediaGalleryStorageCards(storage, selectStorage)
        }
        if (showsDisplayControls) MonitorCatalogDisplayControls(layout == DisplayLayout.LIST, thumbnailSize,
            { list -> selectLayout(if (list) DisplayLayout.LIST else DisplayLayout.GRID) }, selectThumbnailSize)
    }
}

/** Source choice values use the same shared popup/form/footer, without an app-owned Dialog. */
@Composable
public fun MonitorMediaGalleryFilterDialog(filters: MonitorMediaGalleryFilters,
    hasActiveFilters: Boolean, action: (MonitorMediaGalleryFilterAction) -> Unit, close: () -> Unit): Unit {
    MediaFilterPopup(filters.formats, filters.resolutions, emptyList(), false,
        filters.formatSelection, filters.resolutionSelection, emptySet(), null, null,
        onToggleFormat = { action(MonitorMediaGalleryFilterAction.Format(it)) },
        onToggleResolution = { action(MonitorMediaGalleryFilterAction.Resolution(it)) }, onToggleColor = {},
        onDateStart = {}, onDateEnd = {}, onClear = { action(MonitorMediaGalleryFilterAction.Reset) }, onClose = close,
        photoSizes = filters.photoSizes.takeIf { it.isNotEmpty() }?.let { com.opencapture.monitorui.MonitorMediaPhotoSizeChoices(
            it, filters.photoSizeSelection, onToggle = { id -> action(MonitorMediaGalleryFilterAction.PhotoSize(id)) }) },
        dateWindows = filters.dateWindows.takeIf { it.isNotEmpty() }?.let { com.opencapture.monitorui.MonitorMediaDateWindowChoices(
            it, filters.dateWindow, onToggle = { id -> action(MonitorMediaGalleryFilterAction.DateWindow(id)) }) },
        storage = filters.storage.takeIf { it.isNotEmpty() }?.let { com.opencapture.monitorui.MonitorMediaStorageChoices(
            it, filters.storageID, onToggle = { id -> action(MonitorMediaGalleryFilterAction.Storage(id)) }) },
        hasActiveFilters = hasActiveFilters, dialog = true)
}
