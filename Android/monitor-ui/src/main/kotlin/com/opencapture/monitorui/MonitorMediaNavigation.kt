package com.opencapture.monitorui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

/** A count is absent until its source has observed it. */
@Immutable
data class MonitorMediaNavigationCategory(val id: String, val title: String, val count: Int? = null)

/** The enclosing page owns scrolling so category and storage rows share its viewport. */
@Composable
fun MonitorMediaNavigation(
    categories: List<MonitorMediaNavigationCategory>,
    selectedID: String,
    vertical: Boolean,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tabs: @Composable () -> Unit = {
        categories.forEach { category ->
            val selected = category.id == selectedID
            MonitorTab(
                selected = selected,
                vertical = vertical,
                accessibilityLabel = "Show ${category.title} media",
                onClick = { onSelect(category.id) },
                modifier = Modifier
                    .then(if (vertical) Modifier.fillMaxWidth() else Modifier)
                    .semantics { testTag = "monitor.media.category.${category.id}" },
            ) {
                Text(
                    category.title,
                    color = if (selected) MonitorPalette.accent else MonitorPalette.muted,
                    style = MonitorTypography.text(12.5f, FontWeight.SemiBold),
                    maxLines = 1,
                )
                if (vertical) Spacer(Modifier.weight(1f))
                category.count?.let { count ->
                    Text(
                        count.toString(),
                        color = if (selected) MonitorPalette.accent else MonitorPalette.faint,
                        style = MonitorTypography.text(10f, FontWeight.Bold),
                    )
                }
            }
        }
    }
    if (vertical) Column(
        modifier.monitorTabStrip(vertical = true),
        verticalArrangement = Arrangement.spacedBy(0.dp),
    ) { tabs() }
    else Row(modifier.monitorTabStrip(), horizontalArrangement = Arrangement.spacedBy(0.dp)) { tabs() }
}
