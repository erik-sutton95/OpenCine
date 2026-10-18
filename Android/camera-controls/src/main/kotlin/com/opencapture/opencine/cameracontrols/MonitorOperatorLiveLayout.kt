package com.opencapture.opencine.cameracontrols

import com.opencapture.monitorui.LiveMonitorLayout
import com.opencapture.monitorui.MonitorFieldLayout
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

/** Picture framing and scope clearance are common policy; app adapters supply window and decoder facts. */
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
        if (fill && showsToolbar) scopeLeft = maxOf(scopeLeft,
            layout.feed.minX + LivePortraitMetrics.ASSIST_RAIL_EDGE + LivePortraitMetrics.ASSIST_RAIL_EXPANDED)
    } else {
        scopeRight = minOf(scopeRight, layout.settings.minX - 6f)
        if (focusResetAvailable) scopeTop = maxOf(scopeTop, layout.focusReset.maxY)
    }
    val placement = MonitorRect(scopeLeft, scopeTop, maxOf(0f, scopeRight - scopeLeft),
        maxOf(0f, minOf(scopeBottom, layout.viewportHeight) - scopeTop))
    return MonitorOperatorLiveLayout(layout, zones, picture, placement, pictureAspect)
}

/**
 * The field-monitor entry for a source laid out by [LiveMonitorLayout.fieldMonitor] in both orientations, as the
 * Swift field-monitor shell lays out. Portrait fill yields to de-squeeze; a vertical picture always fills. [portraitAspect] is
 * null when the source offers no fit/fill choice now (fit). Scopes float clear of the system band in portrait and
 * of the side rail in landscape, as the Swift surface clears them.
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
    val right = if (field.portrait) viewport.width - viewport.trailing else field.settings.x - 6f
    val floor = if (field.portrait) field.system.y else viewport.height
    val placement = MonitorRect(viewport.leading, viewport.top, maxOf(0f, right - viewport.leading),
        maxOf(0f, floor - viewport.top))
    return MonitorOperatorLiveLayout(layout, null, picture, placement, pictureAspect)
}

/** Where fitted scopes stack: between a portrait fit picture and the camera values. Null in fill and landscape. */
public fun monitorOperatorFittedScopeZone(field: MonitorFieldLayout): MonitorRect? {
    if (!field.portrait || field.fillsPicture) return null
    val room = minOf(184f, maxOf(0f, field.values.y - field.picture.maxY - 32f))
    return MonitorRect(field.picture.x + 14f, field.picture.maxY + 16f, maxOf(0f, field.picture.width - 28f), room)
}
