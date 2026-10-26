package com.opencapture.opencine.cameracontrols.gyro

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * The gyro screens' one layout rule, drawn from the approved mockups, the Android twin of the Swift
 * `GyroAdaptiveStack`. Portrait (narrower than tall): the header text on top, the visual filling the
 * middle, the footer (button or hint) at the bottom, so the visual sits above the button. Landscape:
 * the visual on the left half, header and footer stacked on the right half.
 *
 * [visual] is the ring, glyph or other focal drawing; [header] and [footer] hold the copy and the
 * one action. Same slots, spacing and fractions as the Swift variant.
 */
@Composable
public fun GyroAdaptiveStack(
    modifier: Modifier = Modifier,
    visual: @Composable () -> Unit,
    header: @Composable () -> Unit,
    footer: @Composable () -> Unit,
) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val width = maxWidth
        val height = maxHeight
        if (width < height) {
            Column(
                Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 20.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                header()
                Box(
                    Modifier.fillMaxWidth().weight(1f),
                    contentAlignment = Alignment.Center,
                ) { visual() }
                footer()
            }
        } else {
            Row(
                Modifier.fillMaxSize().padding(vertical = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(24.dp),
            ) {
                Box(
                    Modifier.width(maxOf(0.dp, width * 0.48f - 12.dp)).fillMaxHeight(),
                    contentAlignment = Alignment.Center,
                ) { visual() }
                Column(
                    Modifier.weight(1f).fillMaxHeight().padding(end = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.Start,
                ) {
                    header()
                    footer()
                }
            }
        }
    }
}
