package com.opencapture.monitorui

import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Logical platform points; no display density, camera, or OS state is retained. */
data class MonitorRect(val x: Float, val y: Float, val width: Float, val height: Float) {
    val minX: Float get() = x
    val minY: Float get() = y
    val maxX: Float get() = x + width
    val maxY: Float get() = y + height
    val midX: Float get() = x + width / 2f
    val midY: Float get() = y + height / 2f
    val isEmpty: Boolean get() = width <= 1f || height <= 1f

    fun inset(dx: Float, dy: Float): MonitorRect =
        MonitorRect(
            x + dx,
            y + dy,
            (width - 2f * dx).coerceAtLeast(0f),
            (height - 2f * dy).coerceAtLeast(0f),
        )

    fun intersects(other: MonitorRect): Boolean =
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY

    fun contains(px: Float, py: Float): Boolean = px >= minX && px <= maxX && py >= minY && py <= maxY

    /** Aspect-fit a picture of `aspect` (width/height) inside this well. */
    fun fittedContent(aspect: Float): MonitorRect {
        val ratio = if (aspect.isFinite() && aspect > 0f) aspect else 16f / 9f
        if (height <= 0f) return this
        return if (width / height > ratio) {
            val w = height * ratio
            MonitorRect(x + (width - w) / 2f, y, w, height)
        } else {
            val h = width / ratio
            MonitorRect(x, y + (height - h) / 2f, width, h)
        }
    }
}

/**
 * `FieldMonitorLayout`: a vertical camera is shown whole, resting on the bottom of the well.
 * Height-only sizing overflowed narrow phones and clipped both sides.
 */
fun portraitVerticalPicture(well: MonitorRect): MonitorRect {
    val height = minOf(well.height, well.width * 16f / 9f)
    val width = height * 9f / 16f
    return MonitorRect(well.midX - width / 2f, well.maxY - height, width, height)
}

data class MonitorPortraitLayout(
    val status: MonitorRect,
    val picture: MonitorRect,
    val values: MonitorRect,
    val system: MonitorRect,
    val controlsFloor: Float,
)

/** Device-independent Field Monitor slots. Matches `FieldMonitorLayout`. */
data class MonitorFieldLayout(
    val viewport: MonitorRect,
    val picture: MonitorRect,
    val status: MonitorRect,
    val values: MonitorRect,
    val system: MonitorRect,
    val lock: MonitorRect,
    val gauges: MonitorRect,
    val settings: MonitorRect,
    val media: MonitorRect,
    val record: MonitorRect,
    val display: MonitorRect,
    val assists: MonitorRect,
    val stick: MonitorRect,
    val zoom: MonitorRect,
    val gimbal: MonitorRect,
    val headTrack: MonitorRect,
    val aspectToggle: MonitorRect,
    val focusReset: MonitorRect,
    val portrait: Boolean,
    val tablet: Boolean,
    val fillsPicture: Boolean,
    val controlsFloor: Float,
    /** Live render bounds, independent of the retained gauges/corner contract. */
    val telemetry: MonitorRect = gauges,
) {
    /**
     * The app status badge slot, clear of the lock, the gauges and the status row in either
     * orientation. The badge's touch target stays inside this rect. Swift `FieldMonitorLayout.appBadge`.
     */
    val appBadge: MonitorRect get() = MonitorLayoutPolicy.appBadge(status, listOf(lock, gauges, telemetry))
}

/** Operator choice for the on-feed gimbal joystick diameter. */
enum class MonitorJoystickSize(val raw: String, val side: Float, val label: String) {
    SMALL("small", 88f, "Small"),
    MEDIUM("medium", MonitorLayoutPolicy.STICK_SIDE, "Medium"),
    LARGE("large", 116f, "Large"),
    ;

    companion object {
        fun parse(raw: String?): MonitorJoystickSize = entries.firstOrNull { it.raw == raw } ?: MEDIUM

        fun fromLabel(label: String): MonitorJoystickSize = entries.firstOrNull { it.label == label } ?: MEDIUM
    }
}

/** UI 2.0 layout decisions shared by brand apps; native shells retain the feed. */
object MonitorLayoutPolicy {
    /** Reserve the portrait telemetry band independently of immersive system insets and feed framing. */
    fun portraitHeaderSafeTop(width: Float, height: Float, safeTop: Float): Float =
        if (height > width && width < 600f) max(44f, safeTop) else safeTop

    fun portrait(
        width: Float, height: Float, safeTop: Float, safeBottom: Float,
        fill: Boolean, valuesVisible: Boolean, sourceAspect: Float, valueCount: Int? = null,
    ): MonitorPortraitLayout {
        val vw = max(0f, width)
        val vh = max(0f, height)
        val tablet = min(vw, vh) >= 600f
        val ratio = sourceAspect.takeIf { it.isFinite() && it > 0f } ?: 16f / 9f
        val top = max(0f, safeTop)
        val status = MonitorRect(0f, top, vw, if (tablet) 52f else 44f)
        val systemH = if (tablet) 116f else 100f
        // Record still clears the navigation handle; the whole portrait stack sits low.
        val systemY = max(0f, vh - max(0f, safeBottom - 30f) - systemH)
        val system = MonitorRect(0f, systemY, vw, systemH)
        val valuesH = if (valuesVisible) portraitValuesHeight(valueCount, tablet) else 0f
        val valuesY = max(0f, systemY - 8f - valuesH)
        val floor = max(0f, valuesY - if (valuesVisible) 8f else 0f)
        val frameRatio = if (fill) min(ratio, 9f / 16f) else ratio
        val ceiling = status.maxY
        val wide = tablet && vw / frameRatio > max(0f, floor - ceiling)
        val h = if (wide) max(0f, floor - ceiling) else vw / frameRatio
        val w = if (wide) h * frameRatio else vw
        val y = if (h > vh || h > floor - ceiling) {
            // Impossible chrome clearance yields to canvas-centered picture placement.
            (vh - h) / 2f
        } else {
            val ideal = (vh - h) / 2f
            max(ceiling, min(ideal, floor - h))
        }
        return MonitorPortraitLayout(status, MonitorRect((vw - w) / 2f, y, w, h),
            MonitorRect(14f, valuesY + 4f, max(0f, vw - 28f), valuesH), system, floor)
    }

    /** Portrait tools follow the lower controls floor, independently of picture crop. */
    fun portraitAssists(floor: Float, tablet: Boolean): MonitorRect {
        val side = systemButtonSize(tablet)
        val height = side + 35f
        return MonitorRect(
            8f,
            max(0f, floor - 16f - height),
            side + 8f,
            height,
        )
    }

    /** Landscape camera values sit above the home indicator instead of overlapping it. */
    fun landscapeBottomClearance(safeBottom: Float): Float =
        if (safeBottom > 0f) max(safeBottom, 14f) + 10f else 8f

    /** Two stacked system buttons with 38 total horizontal insets, including the 27-wide expansion lane. */
    fun landscapeAssists(
        viewportHeight: Float, tablet: Boolean, leading: Float = 14f, safeBottom: Float = 0f,
    ): MonitorRect {
        val side = systemButtonSize(tablet)
        val height = side * 2f + 8f + ASSIST_SPACING
        val bottom = landscapeBottomClearance(safeBottom)
        return MonitorRect(
            leading,
            max(0f, viewportHeight - bottom - height),
            side + ASSIST_HORIZONTAL_INSETS,
            height,
        )
    }

    /** Live and playback share this Field Monitor assist slot. */
    fun fieldMonitorAssists(
        width: Float, height: Float, safeTop: Float, safeBottom: Float,
    ): MonitorRect {
        val portrait = height > width
        val tablet = min(width, height) >= 600f
        return if (portrait) {
            val layout = portrait(width, height, safeTop, safeBottom, false, true, 16f / 9f)
            portraitAssists(layout.controlsFloor, tablet)
        } else {
            landscapeAssists(height, tablet, 14f, safeBottom)
        }
    }

    const val MEDIA_FILTER_WIDTH = 320f
    const val MEDIA_FILTER_PREFERRED_HEIGHT = 420f
    const val MEDIA_FILTER_EDGE = 12f
    const val MEDIA_FILTER_BELOW_PAGE_TOP = 56f

    /**
     * Media filter card on an edge-to-edge canvas. Clears cutout and home indicator.
     * Uses the larger short-edge inset so a page that zeros the clean-edge island
     * still keeps this trailing card out of the cutout.
     */
    fun mediaFilterPopup(
        viewportWidth: Float, viewportHeight: Float,
        safeTop: Float, safeLeading: Float, safeBottom: Float, safeTrailing: Float,
        topControlInset: Float = 0f,
    ): MonitorRect {
        val pageTop = max(0f, safeTop) + max(0f, topControlInset) + 10f
        val top = pageTop + MEDIA_FILTER_BELOW_PAGE_TOP
        val bottomPad = max(0f, safeBottom) + MEDIA_FILTER_EDGE
        val hanging = maxOf(0f, safeLeading, safeTrailing, 14f)
        val trailingPad = hanging + MEDIA_FILTER_EDGE
        val leadingPad = MEDIA_FILTER_EDGE
        val maxX = max(leadingPad, viewportWidth - trailingPad)
        val cardWidth = min(MEDIA_FILTER_WIDTH, max(160f, maxX - leadingPad))
        val x = max(leadingPad, maxX - cardWidth)
        val maxHeight = max(140f, viewportHeight - top - bottomPad)
        return MonitorRect(x, top, cardWidth, min(MEDIA_FILTER_PREFERRED_HEIGHT, maxHeight))
    }

    fun portraitAspect(width: Float, floor: Float): MonitorRect =
        MonitorRect(max(0f, width) / 2f - 24f, max(0f, floor - 56f), 48f, 48f)

    /** FieldMonitorLayout portrait stick / zoom / gimbal. */
    /** Default on-feed gimbal joystick diameter. */
    const val STICK_SIDE = 101f

    fun portraitStick(width: Float, floor: Float, side: Float = STICK_SIDE): MonitorRect =
        MonitorRect(max(0f, width) - 16f - side, floor - 16f - side, side, side)

    fun portraitZoom(stick: MonitorRect): MonitorRect =
        MonitorRect(stick.x, stick.y - 44f, 44f, 36f)

    fun portraitGimbal(stick: MonitorRect, zoom: MonitorRect): MonitorRect =
        MonitorRect(stick.maxX - 36f, zoom.y, 36f, 36f)

    fun recordSize(tablet: Boolean): Float = if (tablet) 84f else 70f

    /** FieldMonitorLayout landscape stick: leading of the record well, on the values floor. */
    fun landscapeStick(
        width: Float, floor: Float, recordSize: Float, safeTrailing: Float, side: Float = STICK_SIDE,
    ): MonitorRect {
        val x = max(0f, width) - max(16f + recordSize + 12f, max(0f, safeTrailing) + 6f) - side
        return MonitorRect(x, floor - side, side, side)
    }

    fun landscapeZoom(stick: MonitorRect): MonitorRect = portraitZoom(stick)

    fun landscapeGimbal(stick: MonitorRect, zoom: MonitorRect): MonitorRect = portraitGimbal(stick, zoom)

    fun landscapeValuesHeight(): Float = 43f

    fun landscapeValuesInset(recordSize: Float): Float = 14f + recordSize + 28f

    /**
     * Production Field Monitor geometry. Viewport and insets are inputs;
     * camera brands are absent. Native shells retain the feed.
     */
    fun fieldMonitor(
        width: Float, height: Float,
        safeTop: Float = 0f, safeLeading: Float = 0f, safeBottom: Float = 0f, safeTrailing: Float = 0f,
        sourceAspect: Float = 16f / 9f, fill: Boolean = false, showsValues: Boolean = true,
        topControlInset: Float = 0f, hasDisplayCutout: Boolean = false,
        joystick: MonitorJoystickSize = MonitorJoystickSize.MEDIUM, valueCount: Int? = null,
    ): MonitorFieldLayout {
        val w = max(1f, width)
        val h = max(1f, height)
        val aspect = sourceAspect.takeIf { it.isFinite() && it > 0f } ?: 16f / 9f
        val controlInset = max(0f, min(h, if (topControlInset.isFinite()) topControlInset else 0f))
        val viewport = MonitorRect(0f, 0f, w, h)
        val portrait = h > w
        val tablet = min(w, h) >= 600f
        val rec = recordSize(tablet)
        val button = systemButtonSize(tablet)
        val edge = 8f
        if (portrait) {
            val layout = portrait(w, h, safeTop, safeBottom, fill, showsValues, aspect, valueCount)
            val headerLift = if (tablet) 0f else 6f
            val headerSafeTop = portraitHeaderSafeTop(w, h, safeTop)
            val headerLeading = if (tablet) edge else max(16f, safeLeading + 8f)
            val headerTrailing = if (tablet) edge else max(16f, safeTrailing + 8f)
            val status = MonitorRect(headerLeading,
                max(0f, headerSafeTop - headerLift) + controlInset,
                if (tablet) max(0f, w - 28f) else max(0f, w - headerLeading - headerTrailing), layout.status.height)
            val cy = layout.system.y + layout.system.height / 2f
            val lock = MonitorRect(edge, cy - button / 2f, button, button)
            val display = MonitorRect(edge + button + 8f, lock.y, button, button)
            val record = MonitorRect((w - rec) / 2f, cy - rec / 2f, rec, rec)
            // Same order as landscape: Media sits next to Record, Settings outside it.
            val settings = MonitorRect(w - edge - button, lock.y, button, button)
            val media = MonitorRect(settings.x - button - SETTINGS_MEDIA_GAP, lock.y, button, button)
            val cornerTop = max(0f, headerSafeTop - 24f)
            val gaugeTop = (if (tablet) 82f else max(4f, cornerTop - 16f)) + controlInset
            // Three gauge pills: a trailing row on phone, a stacked column on tablet.
            val gauges = MonitorRect(
                if (tablet) edge else w - edge - 186f, gaugeTop,
                if (tablet) 58f else 186f, if (tablet) 68f else 22f,
            )
            val telemetry = if (tablet) gauges else MonitorRect(w - headerTrailing - 122f, gaugeTop + 13f - headerLift, 122f, 22f)
            val floor = layout.controlsFloor
            val assists = portraitAssists(floor, tablet)
            val stick = portraitStick(w, floor, joystick.side)
            val zoom = portraitZoom(stick)
            val gimbal = portraitGimbal(stick, zoom)
            val compass = headTrack(stick, zoom)
            val aspectToggle = portraitAspect(w, floor)
            val focusReset = MonitorRect(
                max(safeLeading + 8f, assists.x), assists.y - 48f, 40f, 40f,
            )
            return MonitorFieldLayout(
                viewport, layout.picture, status, layout.values, layout.system,
                lock, gauges, settings, media, record, display, assists, stick, zoom, gimbal,
                compass, aspectToggle, focusReset, true, tablet, fill || aspect < 1f,
                floor, telemetry = telemetry,
            )
        }
        val cut = max(0f, max(safeLeading, safeTrailing) - 14f)
        val imageW = min(w - 2f * cut, h * aspect)
        val imageH = imageW / aspect
        val picture = MonitorRect((w - imageW) / 2f, (h - imageH) / 2f, imageW, imageH)
        val system = MonitorRect(0f, 0f, 0f, 0f)
        val hasHome = safeBottom > 0f
        val bottom = if (hasHome) 12f else 8f
        val record = MonitorRect(w - 6f - rec, h - bottom - rec, rec, rec)
        val cutoutHeight = if (safeTrailing >= 55f) 112f else 124f
        val availableDisplayHeight =
            if (safeTrailing > 0f && !tablet) record.y - 8f - (h + cutoutHeight) / 2f - 4f else button
        val dispH = max(36f, min(button, availableDisplayHeight))
        val display = MonitorRect(record.midX - button / 2f, record.y - 8f - dispH, button, dispH)
        val hasCutout = max(safeLeading, safeTrailing) > 0f || hasDisplayCutout
        val cornerClearance = cutoutPhoneCornerInset(h, tablet, hasCutout)
        val cornerTop = (if (tablet) 12f else if (hasCutout) 8f else 52f) + controlInset + max(0f, cornerClearance - 6f)
        val settings = MonitorRect(
            if (tablet) w - 8f - button * 2f - SETTINGS_MEDIA_GAP else record.midX - button / 2f,
            cornerTop, button, button,
        )
        val media = MonitorRect(
            if (tablet) settings.maxX + SETTINGS_MEDIA_GAP else settings.x,
            if (tablet) cornerTop else settings.maxY + SETTINGS_MEDIA_GAP, button, button,
        )
        val lock = MonitorRect(12f, cornerTop, button, button)
        // Gauges share the lock's edge so a 19.5:9 phone's 16:9 picture starts at their trailing edge.
        val gauges = MonitorRect(lock.x, lock.maxY + landscapeGaugeGap(tablet), 58f, 68f)
        val statusX = max(77f, picture.x + 12f)
        val status = MonitorRect(
            statusX, (if (tablet) 4f else 0f) + controlInset,
            max(0f, settings.x - statusX - 12f), if (tablet) 46f else 44f,
        )
        val side = landscapeValuesInset(rec)
        val valuesH = if (showsValues) landscapeValuesHeight() else 0f
        val bottomPad = landscapeBottomClearance(safeBottom)
        val valuesY = h - bottomPad - valuesH
        val values = MonitorRect(side, valuesY + 4f, max(0f, w - side * 2f), valuesH)
        val floor = valuesY - 8f
        val assistHeight = button * 2f + 8f + ASSIST_SPACING
        val assists = MonitorRect(
            12f, max(0f, h - max(4f, bottomPad - 4f) - assistHeight),
            button + ASSIST_HORIZONTAL_INSETS, assistHeight,
        )
        val stick = landscapeStick(w, floor, rec, safeTrailing, joystick.side)
        val zoom = landscapeZoom(stick)
        val gimbal = landscapeGimbal(stick, zoom)
        val compass = headTrack(stick, zoom)
        val focusReset = MonitorRect(
            max(safeLeading + 8f, stick.x - 50f), stick.maxY - 40f, 40f, 40f,
        )
        return MonitorFieldLayout(
            viewport, picture, status, values, system, lock, gauges, settings, media, record, display,
            assists, stick, zoom, gimbal, compass, MonitorRect(0f, 0f, 0f, 0f), focusReset,
            false, tablet, false, floor,
        )
    }

    /**
     * iOS `FieldMonitorLayout.aeUnlock`: capsule 1.5x the Recenter key wide. Landscape:
     * beside Recenter, toward the picture centre. Portrait: mirrored to the left, just
     * right of the View Assist column on Recenter's baseline, clear of Fit/Fill (centred)
     * and the joystick cluster at any width or joystick size.
     */
    fun aeUnlock(reset: MonitorRect, leadingColumnMaxX: Float, pictureMidX: Float, portrait: Boolean): MonitorRect {
        val width = reset.height * 1.5f
        val x = when {
            portrait -> leadingColumnMaxX + 8f
            reset.midX < pictureMidX -> reset.maxX + 8f
            else -> reset.x - 8f - width
        }
        return MonitorRect(x, reset.y, width, reset.height)
    }

    /** The widest an app's own status badge may draw. */
    const val APP_BADGE_WIDTH = 200f

    /** Clearance an app status badge keeps from the status row and from reserved chrome. */
    const val APP_BADGE_GAP = 8f

    /**
     * An app's own status badge (a capture health pill): one touch-target row under the status
     * row, starting at its leading edge and moved past each reserved rect it would touch, so a
     * tap on the badge never lands on the lock or a gauge. Never wider than the status row.
     * Swift `FieldMonitorLayout.appBadge`.
     */
    fun appBadge(status: MonitorRect, reserved: List<MonitorRect>): MonitorRect {
        val y = status.maxY + APP_BADGE_GAP
        var x = status.x
        for (rect in reserved.sortedBy { it.x }) {
            val touchesRow = rect.y < y + MONITOR_MIN_TAP_TARGET_DP + APP_BADGE_GAP && y - APP_BADGE_GAP < rect.maxY
            val touchesColumn = rect.x - APP_BADGE_GAP < x + APP_BADGE_WIDTH && x < rect.maxX + APP_BADGE_GAP
            if (touchesRow && touchesColumn) x = rect.maxX + APP_BADGE_GAP
        }
        return MonitorRect(x, y, max(0f, min(APP_BADGE_WIDTH, status.maxX - x)), MONITOR_MIN_TAP_TARGET_DP)
    }

    /** 44 dp compass above the zoom row, trailing-aligned with the stick. */
    fun headTrack(stick: MonitorRect, zoom: MonitorRect): MonitorRect =
        MonitorRect(stick.maxX - 44f, zoom.y - 8f - 44f, 44f, 44f)

    /** Landscape readouts share the format row's center and stay inside the picture. */
    fun recordingReadoutTrailingInset(statusRight: Float, pictureRight: Float): Float =
        max(8f, statusRight - pictureRight + 12f)
    /** Landscape cutout-phone lock/settings/media drop, as a fraction of HUD height. */
    const val CUTOUT_CORNER_INSET = 0.025f

    fun portraitReadoutTop(tablet: Boolean, safeTop: Float, statusTop: Float, pictureTop: Float): Float {
        // STBY / clock / REC SETUP follow the independent status row, not the feed.
        return statusTop
    }

    fun cutoutPhoneCornerInset(viewportHeight: Float, tablet: Boolean, hasDisplayCutout: Boolean): Float =
        if (!tablet && hasDisplayCutout) CUTOUT_CORNER_INSET * max(0f, viewportHeight) else 0f

    fun systemButtonSize(tablet: Boolean): Float = 48f

    fun assistButtonSize(tablet: Boolean): Float = systemButtonSize(tablet)

    fun assistIconSize(tablet: Boolean): Float = assistCompactIconSize(tablet)

    fun assistCompactIconSize(tablet: Boolean): Float = systemButtonSize(tablet) * 29f / 54f

    const val ASSIST_EXPANSION_GLYPH_LANE = 15f
    const val ASSIST_EXPANSION_BUTTON_WIDTH = 27f
    /** Gap between View Assist tool cells. */
    const val ASSIST_SPACING = 6f
    const val ASSIST_HORIZONTAL_INSETS = 4f * 2f + ASSIST_SPACING + ASSIST_EXPANSION_BUTTON_WIDTH

    fun assistAvailableWidth(screenWidth: Float, portrait: Boolean, tablet: Boolean, cornerRadius: Float = 42f): Float {
        val inset = if (portrait) 14f else max(14f, (cornerRadius * 0.42f).roundToInt().toFloat())
        val recW = (if (tablet) 84f else 70f) + 16f + 12f
        val clusterW = assistButtonSize(tablet) + ASSIST_EXPANSION_BUTTON_WIDTH + 14f
        val pad = if (portrait) 14f + recW else max(inset + clusterW + 12f, 14f + recW)
        return max(1f, screenWidth - pad - inset)
    }

    fun assistCellWidth(screenWidth: Float, portrait: Boolean, tablet: Boolean, cornerRadius: Float = 42f): Float =
        assistButtonSize(tablet)

    data class Panel(val x: Float, val y: Float, val width: Float, val maxHeight: Float)

    /** The smallest distance any capture popup keeps from the top, and its offset under a safe top inset. */
    const val POPUP_TOP_MARGIN_MINIMUM = 8f

    /**
     * The one capture popup top margin, `max(8, safe top + 8)` in dp: the bottom drawer and the
     * top-edge recording categories both keep it. Twin of Swift `MonitorCapturePopupLayout.topMargin`
     * (points); both read `Fixtures/popup-top-margin.tsv`.
     */
    fun popupTopMargin(safeTop: Float): Float = max(POPUP_TOP_MARGIN_MINIMUM, safeTop + POPUP_TOP_MARGIN_MINIMUM)

    fun bottomPanel(panelHeight: Float, width: Float, height: Float, safeLeading: Float,
        safeTrailing: Float, safeTop: Float, safeBottom: Float, portraitFloor: Float? = null): Panel {
        val edge = max(14f, max(safeLeading, safeTrailing) + 4f)
        val panelWidth = min(if (min(width, height) >= 600f) 620f else 480f, max(0f, width - edge * 2f))
        val bottom = if (height > width && portraitFloor != null) min(height, portraitFloor - 12f)
            else height - max(0f, safeBottom)
        val top = popupTopMargin(safeTop)
        val room = max(0f, bottom - top)
        return Panel((width - panelWidth) / 2f, max(top, bottom - min(panelHeight, room)), panelWidth, room)
    }

    /**
     * Format / color / mode open from the top. Portrait sits 6dp below the info bar; landscape
     * floats inside the safe area under the same top margin as [bottomPanel].
     */
    fun topPanel(panelHeight: Float, width: Float, height: Float, safeLeading: Float,
        safeTrailing: Float, safeTop: Float, safeBottom: Float, portraitCeiling: Float? = null,
        portraitFloor: Float? = null): Panel {
        val edge = max(14f, max(safeLeading, safeTrailing) + 4f)
        val panelWidth = min(if (min(width, height) >= 600f) 620f else 480f, max(0f, width - edge * 2f))
        val portrait = height > width
        val margin = popupTopMargin(safeTop)
        val top = if (portrait && portraitCeiling != null) min(height, max(margin, portraitCeiling + 6f))
            else min(height, margin)
        val bottom = if (portrait && portraitFloor != null) min(height, portraitFloor - 12f)
            else height - max(0f, safeBottom)
        val room = max(0f, bottom - top)
        return Panel((width - panelWidth) / 2f, top, panelWidth, room)
    }

    /** Camera values per row: three on a phone in portrait, else one row. Mirrors Swift `FieldMonitorLayout.valueColumns`. */
    fun valueColumns(count: Int, portrait: Boolean, tablet: Boolean): Int =
        if (portrait && !tablet) 3 else count.coerceAtLeast(1)

    /** Space one more row of camera values adds: a 32 dp tile and the grid's 10 dp gap. */
    const val VALUE_ROW_PITCH = 42f

    /**
     * The portrait camera-value band. A phone holds two rows and grows a row pitch for each
     * further row; a tablet keeps one row. A null count keeps the two-row band.
     * Mirrors Swift `FieldMonitorLayout.portraitValuesHeight`.
     */
    fun portraitValuesHeight(count: Int?, tablet: Boolean): Float {
        if (tablet) return 43f
        val columns = valueColumns(count ?: 0, portrait = true, tablet = false)
        val rows = count?.let { (it.coerceAtLeast(1) + columns - 1) / columns } ?: 2
        return 74f + maxOf(0, rows - 2) * VALUE_ROW_PITCH
    }

    fun readoutValueSize(tablet: Boolean): Float = if (tablet) 18f else 16f
    const val READOUT_LABEL_SIZE = 9f
    const val READOUT_LABEL_TRACKING = 1.26f

    const val COMPACT_CAPTURE_HEIGHT = 128f
    const val CAPTURE_DRUM_HEIGHT = 86f
    const val CAPTURE_HEADER_HEIGHT = 22f
    const val CAPTURE_STACK_GAP = 8f
    fun captureTopPadding(fromTop: Boolean, portrait: Boolean, compact: Boolean): Float =
        if (!fromTop) 11f else if (compact || portrait) 12f else 16f

    fun compactCaptureBottomPadding(topPadding: Float): Float =
        max(0f, COMPACT_CAPTURE_HEIGHT - topPadding - CAPTURE_HEADER_HEIGHT - CAPTURE_STACK_GAP - CAPTURE_DRUM_HEIGHT)

    fun showsRecordingCategoryTabs(portrait: Boolean, compact: Boolean): Boolean =
        portrait && !compact

    fun showsCaptureGrabber(compact: Boolean, fromTop: Boolean): Boolean =
        !compact && !fromTop

    /**
     * Landscape page chrome mirrors the larger cutout onto both sides so the
     * cameras list and playback gutters stay centered. Portrait keeps each edge.
     * Live HUD must not use this — it parks controls against the physical notch.
     */
    fun pageSideInsets(landscape: Boolean, safeLeading: Float, safeTrailing: Float): Pair<Float, Float> {
        val leading = max(0f, safeLeading)
        val trailing = max(0f, safeTrailing)
        if (!landscape) return leading to trailing
        val side = max(leading, trailing)
        return side to side
    }

    fun cameraPageTitleSize(tablet: Boolean): Float = if (tablet) 24f else 19f
    const val CAMERA_CARD_CORNER = 13f
    /** Space between the Settings and Media system buttons. */
    const val SETTINGS_MEDIA_GAP = 12f

    /** The drawn height of a telemetry gauge pill (link, phone and camera battery); Swift `FieldMonitorLayout`. */
    fun telemetryGaugeHeight(tablet: Boolean): Float = if (tablet) 22f else 20f

    /**
     * Space between the landscape lock and the gauge column under it: the link pill's padded touch
     * target, centred on its drawn pill, must clear the lock's (Swift `landscapeGaugeGap`).
     */
    fun landscapeGaugeGap(tablet: Boolean): Float = max(6f, (MONITOR_MIN_TAP_TARGET_DP - telemetryGaugeHeight(tablet)) / 2f)
    const val SETTINGS_TITLE_CONTENT_GAP = 8f
    const val SETTINGS_TITLE_MIN_HEIGHT = 24f
    const val DISP_SIZE = 12f
    const val DISP_TRACKING = 0.48f
    const val CAPTURE_PANEL_CORNER = 16f

    /** Floating popups round every corner; only a landscape bottom drawer's attached edge stays square. */
    fun capturePanelTopCorner(fromTop: Boolean, portrait: Boolean): Float = CAPTURE_PANEL_CORNER

    fun capturePanelBottomCorner(fromTop: Boolean, portrait: Boolean): Float =
        if (fromTop || portrait) CAPTURE_PANEL_CORNER else 0f
}
