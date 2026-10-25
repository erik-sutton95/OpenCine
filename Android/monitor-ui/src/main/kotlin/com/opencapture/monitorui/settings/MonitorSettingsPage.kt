package com.opencapture.monitorui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.monitorui.MonitorCameraAction
import com.opencapture.monitorui.MonitorIcon
import com.opencapture.monitorui.MonitorPageHeading
import com.opencapture.monitorui.MonitorPageScaffold
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTab
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorScrollFade
import com.opencapture.monitorui.monitorTabStrip

/** Stable operator navigation. Android sharing remains an optional integration section. */
public enum class MonitorSettingsTab(
    public val title: String, public val subtitle: String, public val pill: String, public val rail: String,
) {
    LINK("Link", "Connection state and link behavior.", "LIVE", "Connection"),
    SHARING("Sharing", "Coming soon.", "SHARE", "Coming soon"),
    ASSIST("View Assist", "Behavior for live-view tools.", "ASSIST", "Scopes & overlays"),
    CONTROLS("Controls", "Touch behavior and safety.", "TOUCH", "Dials and safety"),
    DISPLAY("Display", "Live view buttons and chrome.", "VISIBILITY", "Live view"),
    STORAGE("Storage", "Local cache and integrations.", "DATA", "Cache & accounts"),
    SYSTEM("System", "App-level behavior.", "APP", "App behavior"),
}

/** Actual operator page navigation, session actions and content scroll ownership. */
@Composable
public fun MonitorSettingsPage(
    brand: String,
    selection: MonitorSettingsTab,
    onSelect: (MonitorSettingsTab) -> Unit,
    isLive: Boolean,
    phaseLabel: String,
    disconnect: (() -> Unit)?,
    feedback: () -> Unit = {},
    tabs: List<MonitorSettingsTab> = MonitorSettingsTab.entries,
    modifier: Modifier = Modifier,
    sharingSubtitle: String? = null,
    sharingRail: String? = null,
    tabSpacing: Dp = 6.dp,
    back: (() -> Unit)? = null,
    /** Each tab's saved scroll offset, restored when the tab opens (Swift `scrollOffsets`). */
    scrollOffsets: Map<MonitorSettingsTab, Int> = emptyMap(),
    /** Where the open tab is scrolled to, for the owner of [scrollOffsets]. */
    onScroll: (MonitorSettingsTab, Int) -> Unit = { _, _ -> },
    rows: @Composable ColumnScope.(MonitorSettingsTab) -> Unit,
) {
    val reportScroll by rememberUpdatedState(onScroll)
    MonitorPageScaffold(
        modifier = modifier,
        navigationWidth = 190f,
        heading = { MonitorPageHeading("Operator Setup", brand) },
        navigation = { portrait ->
            Column(
                if (portrait) Modifier.fillMaxWidth() else Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(if (portrait) 9.dp else 8.dp),
            ) {
                if (portrait) {
                    val scroll = rememberScrollState()
                    Row(
                        Modifier.fillMaxWidth().height(44.dp)
                            .monitorScrollFade(scroll, vertical = false).horizontalScroll(scroll)
                            .monitorTabStrip().testTag("monitor.settings.tabs"),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(tabSpacing),
                    ) {
                        tabs.forEach { tab ->
                            SettingsTab(tab, selection, onSelect, feedback, tab != tabs.first(),
                                Modifier.wrapContentWidth(), subtitle = if (tab == MonitorSettingsTab.SHARING) sharingRail else null)
                        }
                    }
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        SettingsSessionStatus(isLive, phaseLabel, Modifier.weight(1f))
                        if (isLive && disconnect != null) SettingsDisconnect(disconnect)
                    }
                } else {
                    val scroll = rememberScrollState()
                    Column(Modifier.weight(1f).monitorScrollFade(scroll).verticalScroll(scroll)) {
                        Column(Modifier.fillMaxWidth().monitorTabStrip(vertical = true)) {
                            tabs.forEach { tab ->
                                SettingsTab(tab, selection, onSelect, feedback, tab != tabs.first(),
                                    Modifier.fillMaxWidth(), vertical = true,
                                    subtitle = if (tab == MonitorSettingsTab.SHARING) sharingRail else null)
                            }
                        }
                    }
                    SettingsSessionStatus(isLive, phaseLabel, Modifier.fillMaxWidth())
                    if (isLive && disconnect != null) SettingsDisconnect(disconnect, Modifier.fillMaxWidth())
                }
            }
        },
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(verticalAlignment = Alignment.Top) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(selection.title, style = MonitorTypography.text(17f, FontWeight.SemiBold), color = MonitorPalette.text)
                    Text(if (selection == MonitorSettingsTab.SHARING) sharingSubtitle ?: selection.subtitle else selection.subtitle, style = MonitorTypography.text(10.5f), color = MonitorPalette.muted, maxLines = 2)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(selection.pill.uppercase(),
                        style = MonitorTypography.readout(10f, FontWeight.Bold).copy(letterSpacing = 0.6.sp, color = MonitorPalette.accent),
                        modifier = Modifier.border(1.dp, MonitorPalette.accent.copy(alpha = 0.16f), CircleShape)
                            .padding(horizontal = 10.dp, vertical = 6.dp))
                    back?.let { action ->
                        MonitorSettingsActionPill("Back", modifier = Modifier.testTag("monitor.page.back"), onClick = action)
                    }
                }
            }
            Spacer(Modifier.height(10.dp))
            key(selection) {
                val scroll = rememberScrollState(scrollOffsets[selection] ?: 0)
                LaunchedEffect(scroll) { snapshotFlow { scroll.value }.collect { reportScroll(selection, it) } }
                var viewportBounds by remember { mutableStateOf<Rect?>(null) }
                val context = MonitorSettingsScrollContext(scroll, viewportBounds)
                // The keyboard shrinks the scroll viewport, so a focused field (the watcher
                // passcode, a number entry) scrolls clear of it instead of hiding under it.
                Box(Modifier.weight(1f).fillMaxWidth().imePadding()
                    .onGloballyPositioned { viewportBounds = it.boundsInRoot() }) {
                    Column(Modifier.fillMaxSize().monitorScrollFade(scroll).verticalScroll(scroll)
                        .padding(bottom = 22.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        CompositionLocalProvider(LocalMonitorSettingsScrollContext provides context) {
                            rows(selection)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsTab(
    tab: MonitorSettingsTab, selection: MonitorSettingsTab, onSelect: (MonitorSettingsTab) -> Unit,
    feedback: () -> Unit, separator: Boolean, modifier: Modifier, vertical: Boolean = false,
    subtitle: String? = null,
) {
    val selected = selection == tab
    val bringIntoView = remember { BringIntoViewRequester() }
    LaunchedEffect(selected) { if (selected) bringIntoView.bringIntoView() }
    MonitorTab(selected, onClick = {
        if (!selected) feedback()
        onSelect(tab)
    }, modifier = modifier.height(44.dp).bringIntoViewRequester(bringIntoView)
        .testTag("monitor.settings.tab.${tab.title}"), vertical = vertical,
        separator = separator, accessibilityLabel = tab.title) {
        Column(Modifier.then(if (vertical) Modifier.fillMaxWidth() else Modifier),
            verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(tab.title, style = MonitorTypography.text(12.5f, FontWeight.SemiBold),
                color = if (selected) MonitorPalette.accent else MonitorPalette.muted, maxLines = 1)
            Text(subtitle ?: tab.rail, style = MonitorTypography.text(10f), color = MonitorPalette.faint, maxLines = 1)
        }
    }
}

@Composable
private fun SettingsDisconnect(onClick: () -> Unit, modifier: Modifier = Modifier) {
    MonitorCameraAction(
        text = "Disconnect", primary = false, enabled = true, contentDescription = "Disconnect",
        onClick = onClick, modifier = modifier, destructive = true,
        icon = { tint -> MonitorIcon(MonitorIcon.LINK_2_OFF, null, Modifier.size(14.dp), tint) },
    )
}

@Composable
private fun SettingsSessionStatus(isLive: Boolean, phaseLabel: String, modifier: Modifier) {
    Row(modifier.background(Color.White.copy(alpha = 0.04f), RoundedCornerShape(10.dp)).padding(9.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(7.dp).background(if (isLive) Color(0.18f, 0.78f, 0.42f) else MonitorPalette.faint, CircleShape))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(if (isLive) "Active link" else "No camera connected",
                style = MonitorTypography.text(11.5f, FontWeight.SemiBold), color = MonitorPalette.text, maxLines = 1)
            Text(phaseLabel, style = MonitorTypography.text(9f), color = MonitorPalette.muted,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
