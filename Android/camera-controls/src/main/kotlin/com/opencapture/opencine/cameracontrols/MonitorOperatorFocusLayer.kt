package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.LocalOperatorHaptics
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import com.opencapture.monitorui.MonitorFocusMark
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.MonitorTrackingBracketValue
import com.opencapture.monitorui.MonitorTrackingLayer
import com.opencapture.monitorui.MonitorTrackingRect
import com.opencapture.opencine.vocabulary.FocusOverlay
import com.opencapture.opencine.vocabulary.LiveTrackingChrome
import com.opencapture.opencine.vocabulary.TrackingBox
import com.opencapture.opencine.vocabulary.TrackingHud

@Composable
public fun MonitorOperatorFocusLayer(hud: TrackingHud, focus: Pair<Float, Float>?, mirrored: Boolean,
    showTapFocusBox: Boolean, modifier: Modifier = Modifier, aeLocked: Boolean = false,
    flippedVertically: Boolean = false, focusLocked: Boolean = false,
    /** A camera-reported AF area (camera orientation, normalized): the focus mark takes its size. */
    focusArea: TrackingBox? = null,
    /** Further camera-reported AF areas (group AF), drawn as plain boxes in the confirmed colour. */
    otherFocusAreas: List<TrackingBox> = emptyList(),
    /** The camera's focus result where the body reports one; null keeps the accent tap box. */
    focusConfirmed: Boolean? = null,
    /** Hold-to-lock progress in 0..1: the focus mark's outline fills while the operator holds. */
    focusLockProgress: Float = 0f) {
    fun bracket(box: TrackingBox, color: Color, width: Float): MonitorTrackingBracketValue {
        val drawn = box.flipped(mirrored, flippedVertically)
        return MonitorTrackingBracketValue(MonitorTrackingRect(drawn.x, drawn.y, drawn.width, drawn.height), color, width)
    }
    val brackets = hud.dimmedFaces.map { bracket(it, LiveDesign.text.copy(alpha = 0.20f), 1.6f) }.toMutableList()
    val showFocus = when (val overlay = hud.overlay) {
        is FocusOverlay.Search -> {
            brackets += bracket(overlay.box, LiveDesign.text.copy(alpha = 0.88f), 1.5f)
            showTapFocusBox
        }
        is FocusOverlay.Subject -> { brackets += bracket(overlay.box, MonitorFocusConfirmed, 2f); false }
        is FocusOverlay.Face -> { brackets += bracket(overlay.box, LiveDesign.text.copy(alpha = 0.92f), 1.6f); false }
        FocusOverlay.Focus -> showTapFocusBox
    }
    fun area(box: TrackingBox): MonitorTrackingRect =
        box.flipped(mirrored, flippedVertically).let { MonitorTrackingRect(it.x, it.y, it.width, it.height) }
    val color = when (MonitorOperatorFocusInk.of(aeLocked, focusConfirmed)) {
        MonitorOperatorFocusInk.AE_LOCK -> LiveDesign.aeLock
        MonitorOperatorFocusInk.CONFIRMED -> MonitorFocusConfirmed
        MonitorOperatorFocusInk.UNCONFIRMED -> LiveDesign.text.copy(alpha = 0.72f)
        MonitorOperatorFocusInk.ACCENT -> LiveDesign.accent
    }
    val mark = if (showFocus && focus != null) MonitorFocusMark(
        Offset(if (mirrored) 1f - focus.first else focus.first,
            if (flippedVertically) 1f - focus.second else focus.second),
        color, aeLocked, focusLocked, area = focusArea?.let(::area), lockProgress = focusLockProgress) else null
    val areas = if (showFocus) otherFocusAreas.map {
        val drawn = area(it)
        MonitorFocusMark(Offset((drawn.x + drawn.width / 2).toFloat(), (drawn.y + drawn.height / 2).toFloat()),
            MonitorFocusConfirmed, area = drawn)
    } else emptyList()
    MonitorTrackingLayer(brackets, mark, modifier, areas)
}

@Composable
public fun MonitorOperatorTrackingCancelButton(box: TrackingBox, feedWidth: Float, feedHeight: Float,
    mirrored: Boolean, flippedVertically: Boolean = false, onClick: () -> Unit) {
    val rect = LiveTrackingChrome.cancelRect(box, feedWidth, feedHeight, mirrored, flippedVertically)
    val haptics = LocalOperatorHaptics.current
    com.opencapture.monitorui.MonitorTrackingCancelButton(MonitorRect(rect.x, rect.y, rect.width, rect.height),
        MonitorFocusConfirmed, LiveDesign.background, onClick = onClick, feedback = { haptics.selection() })
}

/**
 * The focus mark's ink (twin of the SwiftUI `MonitorOperatorFocusInk`): AE lock wins; a camera that
 * reports a focus result shows it confirmed or unconfirmed; otherwise the accent tap box.
 */
public enum class MonitorOperatorFocusInk {
    ACCENT, AE_LOCK, CONFIRMED, UNCONFIRMED;

    public companion object {
        public fun of(aeLocked: Boolean, focusConfirmed: Boolean?): MonitorOperatorFocusInk = when {
            aeLocked -> AE_LOCK
            focusConfirmed == true -> CONFIRMED
            focusConfirmed == false -> UNCONFIRMED
            else -> ACCENT
        }
    }
}

/** The green of a held subject and of camera-confirmed focus. */
private val MonitorFocusConfirmed = Color(0.18f, 0.78f, 0.42f)
