package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.LivePortraitMetrics
import com.opencapture.monitorui.MonitorAssistTool
import com.opencapture.monitorui.MonitorJoystickSize
import com.opencapture.monitorui.MonitorRect
import com.opencapture.monitorui.portraitFillCropContent
import com.opencapture.monitorui.portraitVerticalPicture
import com.opencapture.monitorui.portraitZones
import com.opencapture.opencine.appkit.MonitorAssistState
import com.opencapture.opencine.appkit.MonitorDisplaySection

/** Native window facts, after the platform's system/cutout insets have been observed. */
public data class MonitorOperatorViewport(public val width: Float, public val height: Float,
    public val leading: Float, public val trailing: Float, public val top: Float, public val bottom: Float,
    public val chromeScale: Float, public val hasDisplayCutout: Boolean)

/**
 * Picture framing and scope clearance are common policy; app adapters supply window and decoder facts. Scopes
 * reach the trailing edge as they reach the leading one; the side rail draws above them and keeps its touches
 * (owner hardware pass 2026-10-30). Swift twin: `FieldMonitorLayout.scopeClearance(safeArea:)`.
 */
public fun monitorOperatorLiveLayout(viewport: MonitorOperatorViewport, assist: MonitorAssistState,
    mounts: (MonitorDisplaySection) -> Boolean, portraitAspect: PortraitFeedAspect,
    pictureAspect: Float, verticalPicture: Boolean, joystick: MonitorJoystickSize,
    focusResetAvailable: Boolean, valueCount: Int? = null): MonitorOperatorLiveLayout {
    val portrait = viewport.height > viewport.width
    val desqueezed = assist.isVisible(MonitorAssistTool.DESQ)
    val fill = verticalPicture || (!desqueezed && portraitAspect == PortraitFeedAspect.FILL)
    val showsToolbar = mounts(MonitorDisplaySection.TOOL_BAR)
    val showsValues = mounts(MonitorDisplaySection.CAMERA_VALUES)
    val zones = if (portrait) portraitZones(viewport.width, viewport.height, viewport.top, viewport.bottom,
        assist.clean, fill, if (!assist.clean && !fill && showsToolbar) LivePortraitMetrics.ASSIST else 0f,
        if (verticalPicture) 9f / 16f else 16f / 9f, valueCount) else null
    val base = LiveMonitorLayout.fieldMonitor(viewportWidth = viewport.width, viewportHeight = viewport.height,
        safeLeading = viewport.leading, safeTrailing = viewport.trailing, safeTop = viewport.top, safeBottom = viewport.bottom,
        showsBottomBars = showsToolbar || showsValues, chromeScale = viewport.chromeScale, pictureAspect = pictureAspect,
        hasDisplayCutout = viewport.hasDisplayCutout, fill = fill, showsValues = showsValues, joystick = joystick,
        valueCount = valueCount)
    val layout = if (zones == null) base else base.copy(feed = zones.feed,
        picture = if (verticalPicture && zones.feed.height > 1f) portraitVerticalPicture(zones.feed) else zones.feed,
        usesFieldMonitor = true)
    val picture = if (desqueezed) layout.onFeed.fittedContent(assist.presentedAspect(pictureAspect))
        else if (zones != null && fill && !verticalPicture) portraitFillCropContent(layout.feed) else layout.onFeed
    var scopeTop = layout.safeTop
    var scopeBottom = layout.viewportHeight
    var scopeLeft = layout.safeLeading
    var scopeRight = layout.viewportWidth - layout.safeTrailing
    if (zones != null) {
        scopeBottom = if (layout.capture.height > 1f) layout.capture.y else zones.systemBar.minY
    } else if (focusResetAvailable) {
        scopeTop = maxOf(scopeTop, layout.focusReset.maxY)
    }
    val placement = scopePlacementInside(layout.viewportWidth, layout.viewportHeight, scopeLeft, scopeTop,
        scopeRight, scopeBottom)
    return MonitorOperatorLiveLayout(layout, zones, picture, placement, pictureAspect)
}

/**
 * The field-monitor entry for a source laid out by [LiveMonitorLayout.fieldMonitor] in both orientations, as the
 * Swift field-monitor shell lays out. Portrait fill yields to de-squeeze; a vertical picture always fills. [portraitAspect] is
 * null when the source offers no fit/fill choice now (fit). Scopes float clear of the system band in portrait and
 * reach both side edges in either orientation, fit or fill, as the Swift surface places them.
 */
public fun monitorOperatorFieldLayout(viewport: MonitorOperatorViewport, assist: MonitorAssistState,
    mounts: (MonitorDisplaySection) -> Boolean, portraitAspect: PortraitFeedAspect?, pictureAspect: Float,
    verticalPicture: Boolean, valueCount: Int? = null): MonitorOperatorLiveLayout {
    val desqueezed = assist.isVisible(MonitorAssistTool.DESQ)
    val fill = verticalPicture || (!desqueezed && portraitAspect == PortraitFeedAspect.FILL)
    val showsToolbar = mounts(MonitorDisplaySection.TOOL_BAR)
    val showsValues = mounts(MonitorDisplaySection.CAMERA_VALUES)
    val layout = LiveMonitorLayout.fieldMonitor(viewportWidth = viewport.width, viewportHeight = viewport.height,
        safeLeading = viewport.leading, safeTrailing = viewport.trailing, safeTop = viewport.top,
        safeBottom = viewport.bottom, showsBottomBars = showsToolbar || showsValues, chromeScale = viewport.chromeScale,
        pictureAspect = pictureAspect, hasDisplayCutout = viewport.hasDisplayCutout, fill = fill, showsValues = showsValues,
        valueCount = valueCount)
    val field = checkNotNull(layout.field)
    val picture = if (desqueezed) layout.onFeed.fittedContent(assist.presentedAspect(pictureAspect)) else layout.onFeed
    val right = viewport.width - viewport.trailing
    val floor = if (field.portrait) field.system.y else viewport.height
    val placement = scopePlacementInside(viewport.width, viewport.height, viewport.leading, viewport.top, right, floor)
    return MonitorOperatorLiveLayout(layout, null, picture, placement, pictureAspect)
}

/**
 * The scope area [left, top, right, bottom] intersected with the viewport: apps keep panels inside it
 * and require it inside the viewport. Insets animate on other frames than the viewport size, and a
 * first measure, rotation or split screen can leave the viewport smaller than its insets, so an
 * empty intersection is a zero-size rect at the nearest viewport edge, never one outside it.
 */
private fun scopePlacementInside(width: Float, height: Float, left: Float, top: Float, right: Float,
    bottom: Float): MonitorRect {
    val maxX = maxOf(0f, width)
    val maxY = maxOf(0f, height)
    val x = left.coerceIn(0f, maxX)
    val y = top.coerceIn(0f, maxY)
    return MonitorRect(x, y, spanWithin(x, right.coerceIn(x, maxX)), spanWithin(y, bottom.coerceIn(y, maxY)))
}

/** `end - start`, shortened by float steps when `start` plus it would round past `end`. */
private fun spanWithin(start: Float, end: Float): Float {
    var length = end - start
    while (length > 0f && start + length > end) length = Math.nextDown(length)
    return maxOf(0f, length)
}
