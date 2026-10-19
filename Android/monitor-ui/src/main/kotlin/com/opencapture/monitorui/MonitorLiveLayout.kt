package com.opencapture.monitorui

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// Live view chrome geometry shared by the apps: the compact-phone chrome scale, the safe insets
// handed to the zone map, popup placement, the landscape and portrait live layout and the gimbal
// cluster. Pure layout math on MonitorRect; drawing stays in the apps.

object LiveChromeMetrics {
    /** Unscaled live chrome sizes, in dp. */
    const val LOCK_SIZE_DP = 54f
    const val AUX_SIZE_DP = 54f
    const val RECORD_SIZE_DP = 70f
    const val DISP_WIDTH_DP = 54f
    const val DISP_HEIGHT_DP = 54f
    const val TOP_DECK_HEIGHT_DP = 35f
    const val RAIL_WIDTH_DP = 70f
    const val ZOOM_CHIP_DP = 44f
    const val GIMBAL_STICK_DP = MonitorLayoutPolicy.STICK_SIDE
    const val GIMBAL_KNOB_DP = 41f
    const val FOCUS_RESET_DP = 40f
    const val TOP_PICKER_WIDTH_DP = 480f
    const val CAPTURE_PICKER_WIDTH_DP = 480f
    const val CONTROL_HEIGHT_DP = 44f

    /** Compact-phone multiplier. `fit` / live view set this; tests leave it at 1. */
    var scale: Float = 1f

    val LOCK get() = LiveChromeMetrics.LOCK_SIZE_DP * scale
    val AUX get() = LiveChromeMetrics.AUX_SIZE_DP * scale
    val RECORD get() = LiveChromeMetrics.RECORD_SIZE_DP * scale
    val DISP_W get() = LiveChromeMetrics.DISP_WIDTH_DP * scale
    val DISP_H get() = LiveChromeMetrics.DISP_HEIGHT_DP * scale
    val TOP_DECK_H get() = LiveChromeMetrics.TOP_DECK_HEIGHT_DP * scale
    val TOP_DECK_SIDE get() = 10f * scale
    val TOP_DECK_GAP get() = 12f * scale
    val BOTTOM_INSET get() = 14f * scale
    val BOTTOM_GAP get() = 12f * scale
    val RAIL_W get() = LiveChromeMetrics.RAIL_WIDTH_DP * scale
    val RAIL_SIDE_GUTTER get() = 8f * scale
    val CHROME_TOP get() = 14f * scale
    val CHROME_LEADING get() = 16f * scale
    val CHROME_BOTTOM get() = 12f * scale
    val CHROME_TRAILING get() = 18f * scale
    const val FEED_ASPECT = 16f / 9f
    const val CUTOUT_MIN = 50f
    const val CLASSIC_NOTCH_SHIFT = 10f
    val BATTERY_PILL_W get() = 48f * scale
    val BATTERY_PILL_H get() = 40f * scale
    val BATTERY_PILL_LEADING get() = 8f * scale
    val BATTERY_PILL_GAP get() = 6f * scale
    val BATTERY_INLINE_GAP get() = 12f * scale
    val BATTERY_INLINE_W get() = 52f * scale
    val ZOOM_INSET get() = 10f * scale
    val ZOOM get() = LiveChromeMetrics.ZOOM_CHIP_DP * scale
    val STICK get() = LiveChromeMetrics.GIMBAL_STICK_DP * scale
    val KNOB get() = LiveChromeMetrics.GIMBAL_KNOB_DP * scale
    val STICK_INSET get() = 16f * scale
    val STICK_GAP get() = 8f * scale
    val FOCUS_RESET get() = LiveChromeMetrics.FOCUS_RESET_DP * scale
    val FOCUS_RESET_GAP get() = 24f * scale
    val POPUP_GAP get() = 10f * scale
    val TOP_PICKER_GAP get() = 8f * scale
    val TOP_PICKER_WIDTH get() = LiveChromeMetrics.TOP_PICKER_WIDTH_DP * scale
    val CAPTURE_PICKER_MAX_WIDTH get() = LiveChromeMetrics.CAPTURE_PICKER_WIDTH_DP * scale
    val CONTROL_H get() = LiveChromeMetrics.CONTROL_HEIGHT_DP * scale
    val INFO_PILL_HUG get() = 800f * scale
    val CAPTURE_HUG get() = 512f * scale
    val CAPTURE_CELL_GAP get() = 16f * scale
    /** Picker panel hug (16+16 pad, 34 close header, 14 gap, 176 drum). */
    const val DRUM_PICKER_HEIGHT = 256f
    /** Extra hug when a mode-tab row sits under the drum. */
    const val PICKER_MODE_BAR_HEIGHT = 51f
}

/** Assist takes leftover after the capture pill hugs the trailing edge. */
data class BottomBarSplit(val assistWidth: Float, val captureWidth: Float)

fun bottomBarSplit(barsWidth: Float, gap: Float, captureHug: Float): BottomBarSplit {
    val inner = max(0f, barsWidth - gap)
    val captureShare = inner - inner / 3f
    val capture = min(captureShare, captureHug).coerceAtLeast(0f)
    val assist = max(0f, barsWidth - gap - capture)
    return BottomBarSplit(assist, capture)
}

/**
 * The iPhone Dynamic Island's landscape leading safe-area inset, in points/dp ,
 * the canonical iOS geometry throughout the layout tests (`LiveMonitorLayout`
 * 874×402 with leading 59). `feedFrame` turns it into a left chrome lane: the
 * feed starts at x = 59 while the fixed-margin lock button (chrome insets
 * ignore the safe area; lock spans x 16–56) sits beside it. Compact 16:9
 * viewports may slide a couple of dp left of 59 so the trailing rail still
 * fits in the letterbox.
 */
const val IOS_ISLAND_LANE_DP = 59f

/**
 * Shortest side (sw dp / landscape height) of the iPhone Pro Max / 6.8" class
 * the live HUD is authored against. Compact phones (S25 360 dp) scale chrome
 * down to [CHROME_SCALE_MIN] so record / rail / type match that board.
 */
const val CHROME_SCALE_REFERENCE_DP = 424f

const val CHROME_SCALE_MIN = 0.935f

/** 1 on Pro Max / 6.8"+; [CHROME_SCALE_MIN] on S25-class 360 dp; lerp in between. */
fun monitorChromeScale(smallestWidthDp: Float): Float {
    if (smallestWidthDp <= 0f) return 1f
    return (smallestWidthDp / CHROME_SCALE_REFERENCE_DP).coerceIn(CHROME_SCALE_MIN, 1f)
}

/**
 * The bottom inset handed to the portrait zone map while Android's system bars
 * are hidden. Sticky immersive can report a zero bottom inset, but the physical
 * gesture area is still present. This floor keeps the record control above that
 * edge after the shared layout reclaims its 14dp system-bar lift.
 */
const val PORTRAIT_SYSTEM_RAIL_BOTTOM_INSET_DP = 30f

/**
 * Leading inset handed to the zone map, in dp: the display cutout floored at
 * [IOS_ISLAND_LANE_DP], plus any transient system-bar lane on this edge.
 *
 * Devices whose punch-hole resolves below the core's 50dp cutout threshold
 * would otherwise run the feed edge-to-edge, putting the lock button and
 * battery rail ON the image. Flooring the cutout at the iPhone island lane
 * synthesizes the iOS composition , feed right of the chrome , as a
 * platform-adapter decision, keeping the layout math platform-blind. The
 * floor is a MINIMUM under the physical cutout only; a transient bar on this
 * edge still ADDS its lane on top so the feed clears the overlay.
 */
fun monitorLeadingInsetDp(
    cutoutDp: Float,
    transientBarDp: Float,
    chromeScale: Float = 1f,
): Float {
    // Island floor is geometry, not chrome scale , compact phones still get
    // the iPhone lane. `chromeScale` is unused here (callers pass it).
    return maxOf(cutoutDp, IOS_ISLAND_LANE_DP) + maxOf(0f, transientBarDp - cutoutDp)
}

/**
 * Bottom inset handed to the zone map, in dp.
 *
 * Sticky immersive mode can report no Android navigation-bar inset even
 * though a device still reserves its gesture area at the physical bottom.
 * Keep a portrait-only floor so the fixed system rail and its record button
 * never touch that edge; a real, larger system-bar/cutout inset still wins.
 */
fun monitorBottomInsetDp(rawInsetDp: Float, isPortrait: Boolean): Float =
    if (isPortrait) {
        maxOf(rawInsetDp, PORTRAIT_SYSTEM_RAIL_BOTTOM_INSET_DP)
    } else {
        rawInsetDp
    }

/**
 * Live-view popup geometry (`PanelHost.topPickerBody` / `bottomPickerBody`):
 * a glass card 8dp below a top chip or 10dp above a bottom bar, clamped into the
 * safe viewport , never a full-bleed or centred sheet.
 */
object LivePopupPlacement {
    data class Box(val x: Float, val y: Float, val width: Float, val maxHeight: Float)

    const val EDGE_MARGIN = 8f
    const val ASSIST_MARGIN = 12f
    const val CUTOUT_CLEARANCE = 4f
    const val ASSIST_TOP_INSET = 4f

    fun horizontalBand(
        preferredWidth: Float,
        viewportWidth: Float,
        safeLeading: Float,
        safeTrailing: Float,
        margin: Float,
    ): Triple<Float, Float, Float> {
        val minX = max(margin, safeLeading + CUTOUT_CLEARANCE)
        val maxX = viewportWidth - max(margin, safeTrailing + CUTOUT_CLEARANCE)
        val width = max(0f, min(preferredWidth, maxX - minX))
        return Triple(minX, maxX, width)
    }

    fun leadingX(desired: Float, width: Float, minX: Float, maxX: Float): Float =
        min(max(desired, minX), max(minX, maxX - width))

    /** One viewport-centered floor for every camera-value picker, independent of its source readout. */
    fun bottomCapturePanel(panelHeight: Float, viewportWidth: Float, viewportHeight: Float,
        safeLeading: Float, safeTrailing: Float, safeTop: Float, safeBottom: Float,
        floorY: Float? = null): Box {
        val panel = MonitorLayoutPolicy.bottomPanel(panelHeight, viewportWidth,
            viewportHeight, safeLeading, safeTrailing, safeTop, safeBottom, floorY)
        return Box(panel.x, panel.y, panel.width, panel.maxHeight)
    }

    /** Format / color / mode hang from the top edge, 6dp below the portrait info bar. */
    fun topCapturePanel(panelHeight: Float, viewportWidth: Float, viewportHeight: Float,
        safeLeading: Float, safeTrailing: Float, safeTop: Float, safeBottom: Float,
        ceilingY: Float? = null, floorY: Float? = null): Box {
        val panel = MonitorLayoutPolicy.topPanel(panelHeight, viewportWidth,
            viewportHeight, safeLeading, safeTrailing, safeTop, safeBottom, ceilingY, floorY)
        return Box(panel.x, panel.y, panel.width, panel.maxHeight)
    }

    /**
     * `AssistOptionsPopupAnchor`: card above the toolbar, trailing-aligned
     * to the pressed chip, island clearance. Never a bottom-start sheet over the rail.
     */
    fun assistOptions(
        icon: MonitorRect,
        toolbar: MonitorRect,
        preferredWidth: Float,
        panelHeight: Float,
        viewportWidth: Float,
        viewportHeight: Float,
        safeLeading: Float,
        safeTrailing: Float,
        safeTop: Float,
        safeBottom: Float,
        ceilingY: Float = 0f,
        gap: Float = LiveChromeMetrics.POPUP_GAP,
        keyboardHeight: Float = 0f,
    ): Box {
        val minX =
            maxOf(
                LiveChromeMetrics.CHROME_LEADING,
                safeLeading + CUTOUT_CLEARANCE,
                ASSIST_MARGIN,
            )
        val maxX =
            viewportWidth -
                maxOf(LiveChromeMetrics.CHROME_TRAILING, safeTrailing + CUTOUT_CLEARANCE, ASSIST_MARGIN)
        val width = max(0f, min(preferredWidth, maxX - minX))
        val hasIcon = icon.width > 1f && icon.height > 1f
        val hasToolbar = toolbar.width > 1f && toolbar.height > 1f
        val desiredX =
            when {
                hasIcon -> icon.maxX - width
                hasToolbar -> toolbar.maxX - width
                else -> minX
            }
        val x = leadingX(desired = desiredX, width = width, minX = minX, maxX = maxX)
        val barTop =
            when {
                hasToolbar -> toolbar.minY
                hasIcon -> icon.minY
                else -> viewportHeight - max(EDGE_MARGIN, safeBottom)
            }
        val minY = maxOf(ASSIST_MARGIN, safeTop + ASSIST_TOP_INSET, ceilingY)
        val keyboardTop = viewportHeight - max(0f, keyboardHeight)
        val boxBottom = min(barTop, keyboardTop) - gap
        val maxHeight = max(0f, boxBottom - minY)
        val height = min(max(0f, panelHeight), maxHeight)
        val y = max(minY, boxBottom - height)
        return Box(x = x, y = y, width = width, maxHeight = maxHeight)
    }
}

data class LiveMonitorLayout(
    val viewportWidth: Float,
    val viewportHeight: Float,
    val feed: MonitorRect,
    val picture: MonitorRect,
    val lock: MonitorRect,
    val battery: MonitorRect,
    val topDeck: MonitorRect,
    val assist: MonitorRect,
    val capture: MonitorRect,
    val rail: MonitorRect,
    val settings: MonitorRect,
    val media: MonitorRect,
    val record: MonitorRect,
    val disp: MonitorRect,
    val isWidthConstrained: Boolean,
    val showsBottomBars: Boolean,
    val safeLeading: Float,
    val safeTrailing: Float,
    val safeTop: Float,
    val safeBottom: Float,
    val usesFieldMonitor: Boolean = false,
    /** Operator joystick diameter at chrome scale 1 (Small / Medium / Large). */
    val stickSide: Float = MonitorLayoutPolicy.STICK_SIDE,
    val field: MonitorFieldLayout? = null,
) {
    val onFeed: MonitorRect
        get() = if (picture.width > 1f) picture else feed

    fun gimbalCluster(showGimbalButton: Boolean = false): GimbalCluster {
        if (usesFieldMonitor) {
            val portrait = viewportHeight > viewportWidth
            val floor =
                when {
                    capture.height > 1f -> capture.y - 12f
                    portrait && rail.height > 1f -> rail.y - 8f
                    else ->
                        viewportHeight -
                            MonitorLayoutPolicy.landscapeBottomClearance(safeBottom) - 8f
                }
            val stick =
                if (portrait) {
                    MonitorLayoutPolicy.portraitStick(viewportWidth, floor, stickSide)
                } else {
                    MonitorLayoutPolicy.landscapeStick(
                        viewportWidth, floor, record.width, safeTrailing, stickSide,
                    )
                }
            val zoom = MonitorLayoutPolicy.portraitZoom(stick)
            val gimbal = MonitorLayoutPolicy.portraitGimbal(stick, zoom)
            return GimbalCluster(
                MonitorRect(stick.x, stick.y, stick.width, stick.height),
                MonitorRect(zoom.x, zoom.y, zoom.width, zoom.height),
                if (showGimbalButton) MonitorRect(gimbal.x, gimbal.y, gimbal.width, gimbal.height)
                else MonitorRect(0f, 0f, 0f, 0f),
            )
        }
        val inset = LiveChromeMetrics.STICK_INSET
        val gap = LiveChromeMetrics.STICK_GAP
        var barTop = Float.POSITIVE_INFINITY
        if (showsBottomBars) {
            if (capture.height > 1f) barTop = min(barTop, capture.minY)
        }
        val floorY =
            if (barTop < Float.POSITIVE_INFINITY) min(feed.maxY - inset, barTop - gap)
            else feed.maxY - inset
        // Landscape owns a separate trailing record/DISP rail. Park the whole
        // cluster to its leading side instead of lifting it into DISP.
        val landscape = viewportWidth >= viewportHeight
        val gimbalWell = if (landscape && record.width > 1f) {
            feed.copy(width = max(0f, min(feed.maxX, record.minX - 2f) - feed.minX))
        } else feed
        val avoid = if (!landscape && record.width > 1f) record else null
        return GimbalCluster.inTrailingBottom(
            well = gimbalWell,
            floorY = floorY,
            canvasMaxY = viewportHeight - max(0f, safeBottom),
            avoid = avoid,
            stickSize = LiveChromeMetrics.STICK * stickSide / LiveChromeMetrics.GIMBAL_STICK_DP,
            zoomSize = LiveChromeMetrics.ZOOM,
            gap = gap,
            inset = inset,
            showGimbalButton = showGimbalButton,
        )
    }

    val zoomButton: MonitorRect
        get() = gimbalCluster().zoom

    val gimbalStick: MonitorRect
        get() = gimbalCluster().stick

    val focusReset: MonitorRect
        get() {
            if (usesFieldMonitor) {
                if (viewportHeight > viewportWidth) {
                    return MonitorRect(max(safeLeading + 8f, assist.x), assist.y - 48f, 40f, 40f)
                }
                val stick = gimbalCluster().stick
                return MonitorRect(
                    max(safeLeading + 8f, stick.x - 50f),
                    stick.maxY - 40f, 40f, 40f,
                )
            }
            val size = LiveChromeMetrics.FOCUS_RESET
            if (viewportHeight > viewportWidth) {
                val well = onFeed
                return MonitorRect(well.minX + 10f, well.maxY - size - 10f, size, size)
            }
            val towardFeed =
                if (battery.midX < feed.midX) {
                    battery.maxX + LiveChromeMetrics.FOCUS_RESET_GAP
                } else {
                    battery.minX - LiveChromeMetrics.FOCUS_RESET_GAP
                }
            val baseY = (if (assist.height > 1f) assist.minY else viewportHeight) - 30f
            return MonitorRect(towardFeed - size / 2f, baseY - size / 2f, size, size)
        }

    /** iOS `aeUnlock`. Portrait without an assist column mirrors Recenter to the well's left edge. */
    val aeUnlock: MonitorRect
        get() {
            val reset = focusReset
            val portrait = viewportHeight > viewportWidth
            val leading = if (usesFieldMonitor && assist.width > 1f) assist.maxX else onFeed.minX + 2f
            val r = MonitorLayoutPolicy.aeUnlock(
                MonitorRect(reset.x, reset.y, reset.width, reset.height),
                leading, feed.midX, portrait,
            )
            return MonitorRect(r.x, r.y, r.width, r.height)
        }

    companion object {
        fun fit(
            viewportWidth: Float,
            viewportHeight: Float,
            safeLeading: Float,
            safeTrailing: Float,
            safeTop: Float,
            safeBottom: Float,
            showsBottomBars: Boolean,
            chromeScale: Float = 1f,
            pictureAspect: Float? = null,
            hasDisplayCutout: Boolean = false,
        ): LiveMonitorLayout {
            LiveChromeMetrics.scale = chromeScale
            val vw = max(0f, viewportWidth)
            val vh = max(0f, viewportHeight)
            val constrained = isWidthConstrained(vw, vh)
            val chrome = chromeRect(vw, vh)
            val feed = feedFrame(vw, vh, safeLeading, safeTrailing)
            val picture =
                pictureFrame(
                    aspect = pictureAspect ?: LiveChromeMetrics.FEED_ASPECT,
                    well = feed,
                    viewportWidth = vw,
                    viewportHeight = vh,
                    safeLeading = safeLeading,
                    safeTrailing = safeTrailing,
                )
            val lock = lockRect(chrome)
            val battery = batteryRect(chrome, lock, constrained)
            val rail = rightRailRect(vw, chrome, feed)
            val slots =
                if (constrained) constrainedSlots(vh, chrome, lock)
                else railSlots(rail, if (showsBottomBars) LiveChromeMetrics.CONTROL_H else 0f)
            val bars = bottomBand(vw, vh, chrome, constrained)
            var layout =
                LiveMonitorLayout(
                    viewportWidth = vw,
                    viewportHeight = vh,
                    feed = feed,
                    picture = picture,
                    lock = lock,
                    battery = battery,
                    topDeck = MonitorRect(0f, 0f, 0f, 0f),
                    assist = bars.first,
                    capture = bars.second,
                    rail = rail,
                    settings = slots.settings,
                    media = slots.media,
                    record = slots.record,
                    disp = slots.disp,
                    isWidthConstrained = constrained,
                    showsBottomBars = showsBottomBars,
                    safeLeading = safeLeading,
                    safeTrailing = safeTrailing,
                    safeTop = safeTop,
                    safeBottom = safeBottom,
                )
            layout =
                layout.copy(
                    topDeck =
                        topDeckRect(layout.feed, layout.lock, layout.battery, layout.rail, constrained),
                )
            if (vw >= vh) {
                val tablet = min(vw, vh) >= 600f
                val btn = MonitorLayoutPolicy.systemButtonSize(tablet)
                val record = if (tablet) 84f else 70f
                val edge = 14f
                val recordX = vw - 10f - record
                val recordY = vh - 16f - record
                val recordButtonX = recordX + (record - btn) / 2f
                val buttonX = if (tablet) vw - 14f - btn else recordButtonX
                val top = if (tablet) 12f else if (max(safeLeading, safeTrailing) < 20f) 52f else 8f
                val cornerDrop = MonitorLayoutPolicy.cutoutPhoneCornerInset(
                    vh, tablet, hasDisplayCutout)
                val readoutY = if (tablet) 4f else 0f
                val stackTop = top + cornerDrop
                val lockY = stackTop
                val valuesInset = if (tablet) 140f else 112f
                layout = layout.copy(
                    lock = MonitorRect(edge, lockY, btn, btn),
                    battery = MonitorRect(edge, lockY + btn + 8f, 46f, 54f),
                    topDeck = MonitorRect(max(72f, feed.minX + 12f), readoutY,
                        max(0f, (if (tablet) buttonX - btn - 8f else buttonX) - 12f -
                            max(72f, feed.minX + 12f)), if (tablet) 46f else 44f),
                    settings = MonitorRect(if (tablet) buttonX - btn - 8f else buttonX, stackTop, btn, btn),
                    media = MonitorRect(buttonX, if (tablet) stackTop else stackTop + btn + 8f, btn, btn),
                    record = MonitorRect(recordX, recordY, record, record),
                    disp = MonitorRect(recordButtonX, recordY - 8f - btn, btn, btn),
                    rail = MonitorRect(recordX, 0f, record, vh),
                    capture = MonitorRect(
                        valuesInset,
                        vh - MonitorLayoutPolicy.landscapeBottomClearance(safeBottom) - 44f + 4f,
                        max(0f, vw - 2 * valuesInset), 44f),
                    assist = MonitorLayoutPolicy.landscapeAssists(
                        vh, tablet, edge, safeBottom).let {
                        MonitorRect(it.x, it.y, it.width, it.height)
                    },
                )
            }
            return layout
        }

        /** Production chrome. `fit` remains the compatibility path for tests. */
        fun fieldMonitor(
            viewportWidth: Float,
            viewportHeight: Float,
            safeLeading: Float,
            safeTrailing: Float,
            safeTop: Float,
            safeBottom: Float,
            showsBottomBars: Boolean,
            chromeScale: Float = 1f,
            pictureAspect: Float? = null,
            hasDisplayCutout: Boolean = false,
            fill: Boolean = false,
            showsValues: Boolean = true,
            topControlInset: Float = 0f,
            joystick: MonitorJoystickSize = MonitorJoystickSize.MEDIUM,
            valueCount: Int? = null,
        ): LiveMonitorLayout {
            LiveChromeMetrics.scale = chromeScale
            val p =
                MonitorLayoutPolicy.fieldMonitor(
                    viewportWidth, viewportHeight, safeTop, safeLeading, safeBottom, safeTrailing,
                    pictureAspect ?: LiveChromeMetrics.FEED_ASPECT, fill, showsValues,
                    topControlInset, hasDisplayCutout, joystick, valueCount,
                )
            fun slot(rect: MonitorRect) =
                MonitorRect(rect.x, rect.y, rect.width, rect.height)
            return LiveMonitorLayout(
                viewportWidth = viewportWidth,
                viewportHeight = viewportHeight,
                feed = slot(p.picture),
                picture = slot(p.picture),
                lock = slot(p.lock),
                battery = slot(p.telemetry),
                topDeck = slot(p.status),
                assist = slot(p.assists),
                capture = slot(p.values),
                rail = slot(p.system),
                settings = slot(p.settings),
                media = slot(p.media),
                record = slot(p.record),
                disp = slot(p.display),
                isWidthConstrained = !p.tablet && viewportWidth < 740f,
                showsBottomBars = showsBottomBars,
                safeLeading = safeLeading,
                safeTrailing = safeTrailing,
                safeTop = safeTop,
                safeBottom = safeBottom,
                usesFieldMonitor = true,
                stickSide = joystick.side,
                field = p,
            )
        }

        fun isWidthConstrained(vw: Float, vh: Float, aspect: Float = LiveChromeMetrics.FEED_ASPECT): Boolean =
            vh <= vw && vh * aspect > vw + 0.5f

        private fun chromeRect(vw: Float, vh: Float): MonitorRect =
            MonitorRect(
                LiveChromeMetrics.CHROME_LEADING,
                LiveChromeMetrics.CHROME_TOP,
                max(0f, vw - LiveChromeMetrics.CHROME_LEADING - LiveChromeMetrics.CHROME_TRAILING),
                max(0f, vh - LiveChromeMetrics.CHROME_TOP - LiveChromeMetrics.CHROME_BOTTOM),
            )

        /**
         * Center the displayed raster in the cinema well. A 9:16 camera flip
         * pillarboxes here so the rail , keyed off the 16:9 well , never moves.
         */
        fun pictureFrame(
            aspect: Float,
            well: MonitorRect,
            viewportWidth: Float,
            viewportHeight: Float,
            safeLeading: Float,
            safeTrailing: Float,
        ): MonitorRect {
            val ratio = if (aspect > 0.2f) aspect else LiveChromeMetrics.FEED_ASPECT
            if (well.width < 1f || well.height < 1f) return well
            if (abs(ratio - LiveChromeMetrics.FEED_ASPECT) < 0.02f) return well
            val vw = max(0f, viewportWidth)
            val vh = max(0f, viewportHeight)
            if (vh > vw || vh <= 0f) return well
            var width = vh * ratio
            var height = vh
            if (width > vw + 0.5f) {
                width = vw
                height = vw / ratio
            }
            val lead = if (safeLeading >= LiveChromeMetrics.CUTOUT_MIN) safeLeading else 0f
            val trail = if (safeTrailing >= LiveChromeMetrics.CUTOUT_MIN) safeTrailing else 0f
            val minX = lead
            val maxX = max(minX, vw - trail - width)
            val x = min(max((vw - width) / 2f, minX), maxX)
            val y = (vh - height) / 2f
            return MonitorRect(x, y, width, height)
        }

        private fun feedFrame(vw: Float, vh: Float, safeLeading: Float, safeTrailing: Float): MonitorRect {
            val aspect = LiveChromeMetrics.FEED_ASPECT
            if (vh > vw) return MonitorRect(0f, 0f, vw, vw / aspect)
            val width = vh * aspect
            if (width > vw + 0.5f) {
                val height = vw / aspect
                return MonitorRect(0f, (vh - height) / 2f, vw, height)
            }
            // UI 2.0 keeps the picture centered when the device rotates left/right.
            // Only the chrome changes its clearance around the physical cutout.
            return MonitorRect(max(0f, (vw - width) / 2f), 0f, width, vh)
        }

        private fun isClassicNotch(leading: Float, trailing: Float): Boolean {
            val minimum = min(max(0f, leading), max(0f, trailing))
            val maximum = max(max(0f, leading), max(0f, trailing))
            return minimum >= 40f && maximum <= 50f && abs(leading - trailing) < 4f
        }

        private fun lockRect(chrome: MonitorRect): MonitorRect {
            val size = LiveChromeMetrics.LOCK
            return MonitorRect(
                chrome.minX,
                chrome.minY + (LiveChromeMetrics.TOP_DECK_H - size) / 2f,
                size,
                size,
            )
        }

        private fun batteryRect(chrome: MonitorRect, lock: MonitorRect, constrained: Boolean): MonitorRect {
            if (constrained) {
                return MonitorRect(
                    chrome.minX + LiveChromeMetrics.LOCK + LiveChromeMetrics.BATTERY_INLINE_GAP,
                    lock.minY,
                    LiveChromeMetrics.BATTERY_INLINE_W,
                    LiveChromeMetrics.LOCK,
                )
            }
            return MonitorRect(
                LiveChromeMetrics.BATTERY_PILL_LEADING,
                lock.maxY + LiveChromeMetrics.BATTERY_PILL_GAP,
                LiveChromeMetrics.BATTERY_PILL_W,
                LiveChromeMetrics.BATTERY_PILL_H,
            )
        }

        private fun rightRailRect(vw: Float, chrome: MonitorRect, feed: MonitorRect): MonitorRect {
            val railWidth = min(chrome.width, LiveChromeMetrics.RAIL_W)
            val laneX = min(vw, max(0f, feed.maxX))
            val laneWidth = max(0f, vw - laneX)
            return if (laneWidth >= railWidth) {
                MonitorRect(laneX + (laneWidth - railWidth) / 2f, chrome.minY, railWidth, chrome.height)
            } else {
                // Prefer clipping the screen edge over covering the picture.
                // Hug-to-chrome.maxX jumped ~20 dp onto the feed when the lane
                // was only a couple of dp short of RAIL_W.
                MonitorRect(laneX, chrome.minY, railWidth, chrome.height)
            }
        }

        private data class RailSlots(
            val settings: MonitorRect,
            val media: MonitorRect,
            val record: MonitorRect,
            val disp: MonitorRect,
        )

        private fun railSlots(rail: MonitorRect, bottomBarHeight: Float): RailSlots {
            val aux = LiveChromeMetrics.AUX
            val rec = LiveChromeMetrics.RECORD
            val dispW = LiveChromeMetrics.DISP_W
            val dispH = LiveChromeMetrics.DISP_H
            val recordCenterX = max(rec / 2f, rail.width - rec / 2f)
            val settingsCenterY = aux / 2f
            val recordCenterY = rail.height / 2f
            val mediaCenterY = (settingsCenterY + aux / 2f + recordCenterY - rec / 2f) / 2f
            val bottomBarTop = max(0f, rail.height - max(0f, bottomBarHeight))
            val dispHalf = dispH / 2f
            val clearOfRecord = recordCenterY + rec / 2f + dispHalf
            val displayCenterY =
                if (bottomBarHeight > 0f) (recordCenterY + rec / 2f + bottomBarTop) / 2f
                else max(clearOfRecord, rail.height - dispHalf)

            fun slot(cx: Float, cy: Float, w: Float, h: Float) =
                MonitorRect(rail.minX + cx - w / 2f, rail.minY + cy - h / 2f, w, h)

            return RailSlots(
                settings = slot(recordCenterX, settingsCenterY, aux, aux),
                media = slot(recordCenterX, mediaCenterY, aux, aux),
                record = slot(recordCenterX, recordCenterY, rec, rec),
                disp = slot(recordCenterX, displayCenterY, dispW, dispH),
            )
        }

        private fun constrainedSlots(vh: Float, chrome: MonitorRect, lock: MonitorRect): RailSlots {
            val aux = LiveChromeMetrics.AUX
            val gap = LiveChromeMetrics.BOTTOM_GAP
            val bandCenterY = chrome.minY + LiveChromeMetrics.TOP_DECK_H / 2f
            val settings = MonitorRect(chrome.maxX - aux, bandCenterY - aux / 2f, aux, aux)
            val media = MonitorRect(settings.minX - gap - aux, bandCenterY - aux / 2f, aux, aux)
            val rec = LiveChromeMetrics.RECORD
            val recordBottom = vh - LiveChromeMetrics.BOTTOM_INSET
            val record = MonitorRect(chrome.maxX - rec, recordBottom - rec, rec, rec)
            val disp =
                MonitorRect(
                    record.minX - gap - LiveChromeMetrics.DISP_W,
                    record.midY - LiveChromeMetrics.DISP_H / 2f,
                    LiveChromeMetrics.DISP_W,
                    LiveChromeMetrics.DISP_H,
                )
            return RailSlots(settings, media, record, disp)
        }

        private fun topDeckRect(
            feed: MonitorRect,
            lock: MonitorRect,
            battery: MonitorRect,
            rail: MonitorRect,
            constrained: Boolean,
        ): MonitorRect {
            val gap = LiveChromeMetrics.TOP_DECK_GAP
            val side = LiveChromeMetrics.TOP_DECK_SIDE
            var left = feed.minX + side
            var right = feed.maxX - side
            val clusterRight = max(lock.maxX, battery.maxX)
            val clusterLeft = min(lock.minX, battery.minX)
            if (clusterRight < feed.midX) left = max(left, clusterRight + gap)
            if (clusterLeft > feed.midX) right = min(right, clusterLeft - gap)
            if (constrained) {
                val reserved = 2f * LiveChromeMetrics.AUX + 2f * LiveChromeMetrics.BOTTOM_GAP
                val inset = side + reserved + gap
                left = max(left, feed.minX + inset)
                right = min(right, feed.maxX - inset)
            } else if (rail.midX > feed.midX) {
                right = min(right, rail.minX - gap)
            } else {
                left = max(left, rail.maxX + gap)
            }
            val band = max(0f, right - left)
            // Center a content-capped pill in the feed-anchored band (iOS positions
            // LiveTopChrome at topDeck.mid; FitScale centres InfoPill).
            val hug = min(band, LiveChromeMetrics.INFO_PILL_HUG)
            return MonitorRect(
                left + (band - hug) / 2f,
                LiveChromeMetrics.CHROME_TOP,
                hug,
                LiveChromeMetrics.TOP_DECK_H,
            )
        }

        private fun bottomBand(
            @Suppress("UNUSED_PARAMETER") vw: Float,
            vh: Float,
            chrome: MonitorRect,
            constrained: Boolean,
        ): Pair<MonitorRect, MonitorRect> {
            val reserved =
                LiveChromeMetrics.RECORD + LiveChromeMetrics.DISP_W + 2f * LiveChromeMetrics.BOTTOM_GAP
            val barsWidth = if (constrained) max(0f, chrome.width - reserved) else chrome.width
            val gap = LiveChromeMetrics.BOTTOM_GAP
            val y = vh - LiveChromeMetrics.BOTTOM_INSET - LiveChromeMetrics.CONTROL_H
            val split = bottomBarSplit(barsWidth, gap, LiveChromeMetrics.CAPTURE_HUG)
            val capture = MonitorRect(chrome.minX + barsWidth - split.captureWidth, y, split.captureWidth, LiveChromeMetrics.CONTROL_H)
            val assist = MonitorRect(chrome.minX, y, split.assistWidth, LiveChromeMetrics.CONTROL_H)
            return assist to capture
        }
    }
}

/**
 * Lockstep with Swift `GimbalCluster`. Stick, zoom chip, and gimbal-controls
 * button as one parking spot. The button is a zoom-sized circle leading of
 * zoom. Head Lock is a zoom-sized compass above that row, trailing-aligned
 * with the stick. The stick does not move.
 */
data class GimbalCluster(
    val stick: MonitorRect,
    val zoom: MonitorRect,
    val controls: MonitorRect,
) {
    val headTrack: MonitorRect
        get() {
            val y = min(zoom.minY, stick.minY) - GAP - ZOOM
            return MonitorRect(stick.maxX - ZOOM, y, ZOOM, ZOOM)
        }

    val bounds: MonitorRect
        get() {
            var minX = min(stick.minX, zoom.minX)
            var minY = min(stick.minY, zoom.minY)
            var maxX = max(stick.maxX, zoom.maxX)
            var maxY = max(stick.maxY, zoom.maxY)
            if (controls.width > 1f) {
                minX = min(minX, controls.minX)
                minY = min(minY, controls.minY)
                maxX = max(maxX, controls.maxX)
                maxY = max(maxY, controls.maxY)
            }
            return MonitorRect(minX, minY, max(0f, maxX - minX), max(0f, maxY - minY))
        }

    fun offset(dx: Float, dy: Float): GimbalCluster =
        GimbalCluster(stick.offset(dx, dy), zoom.offset(dx, dy), controls.offset(dx, dy))

    companion object {
        const val STICK = 88f
        const val ZOOM = 44f
        const val GAP = 8f
        const val INSET = 16f

        fun inTrailingBottom(
            well: MonitorRect,
            floorY: Float,
            canvasMaxY: Float,
            avoid: MonitorRect? = null,
            stickSize: Float = STICK,
            zoomSize: Float = ZOOM,
            gap: Float = GAP,
            inset: Float = INSET,
            showGimbalButton: Boolean = false,
        ): GimbalCluster {
            val stickSize = max(0f, stickSize)
            val inset = max(0f, inset)
            val canvasFloor = canvasMaxY - inset
            val stickMaxY = min(min(floorY, well.maxY - inset), canvasFloor)
            var stickY = max(well.minY + inset, stickMaxY - stickSize)
            var stickX = well.maxX - inset - stickSize
            stickX = min(max(stickX, well.minX + inset), max(well.minX, well.maxX - inset - stickSize))
            var cluster =
                stacked(
                    stickX = stickX,
                    stickY = stickY,
                    well = well,
                    stickSize = stickSize,
                    zoomSize = zoomSize,
                    gap = gap,
                    showGimbalButton = showGimbalButton,
                )
            cluster = dodge(cluster, avoid, well, gap, inset)
            return cluster
        }

        private fun stacked(
            stickX: Float,
            stickY: Float,
            well: MonitorRect,
            stickSize: Float,
            zoomSize: Float,
            gap: Float,
            showGimbalButton: Boolean,
        ): GimbalCluster {
            val zoomSize = max(0f, zoomSize)
            val gap = max(0f, gap)
            val stick = MonitorRect(stickX, stickY, stickSize, stickSize)
            val stackedY = stick.minY - gap - zoomSize
            val zoomY = max(well.minY, stackedY)
            val button: MonitorRect
            val zoomX: Float
            if (showGimbalButton) {
                val trailing = min(stick.maxX, well.maxX)
                val buttonX = trailing - zoomSize
                button = MonitorRect(buttonX, zoomY, zoomSize, zoomSize)
                zoomX = min(max(well.minX, button.minX - gap - zoomSize), max(well.minX, well.maxX - zoomSize))
            } else {
                button = MonitorRect(stick.minX, stick.minY, 0f, 0f)
                zoomX = min(max(well.minX, stick.maxX - zoomSize), max(well.minX, well.maxX - zoomSize))
            }
            val zoom = MonitorRect(zoomX, zoomY, zoomSize, zoomSize)
            return GimbalCluster(stick, zoom, button)
        }

        private fun dodge(
            cluster: GimbalCluster,
            avoid: MonitorRect?,
            well: MonitorRect,
            gap: Float,
            inset: Float,
        ): GimbalCluster {
            if (avoid == null || avoid.width <= 1f || avoid.height <= 1f) return cluster
            val padded = avoid.inset(-gap, -gap)
            if (!cluster.bounds.intersects(padded)) return cluster
            // Width-constrained tablets park record on the canvas floor. Lift
            // the cluster above it and keep the trailing edge.
            val liftedMaxY = avoid.minY - gap
            val liftedMinY = liftedMaxY - cluster.bounds.height
            if (liftedMinY >= well.minY + inset) {
                return cluster.offset(0f, liftedMaxY - cluster.bounds.maxY)
            }
            val dx =
                if (avoid.midX >= cluster.bounds.midX) {
                    avoid.minX - gap - cluster.bounds.maxX
                } else {
                    avoid.maxX + gap - cluster.bounds.minX
                }
            var next = cluster.offset(dx, 0f)
            val minX = well.minX + inset
            if (next.bounds.minX < minX) next = next.offset(minX - next.bounds.minX, 0f)
            val maxX = well.maxX - inset
            if (next.bounds.maxX > maxX) next = next.offset(maxX - next.bounds.maxX, 0f)
            return next
        }
    }
}

private fun MonitorRect.offset(dx: Float, dy: Float): MonitorRect = copy(x = x + dx, y = y + dy)

data class PortraitZones(
    val topBar: MonitorRect,
    val feed: MonitorRect,
    val assistToolbar: MonitorRect,
    val controls: MonitorRect,
    val systemBar: MonitorRect,
)

object LivePortraitMetrics {
    val TOP_BAR get() = 44f * LiveChromeMetrics.scale
    val TOP_BAR_LIFT get() = 8f * LiveChromeMetrics.scale
    val SYSTEM_BAR get() = 100f * LiveChromeMetrics.scale
    val SYSTEM_BAR_LIFT get() = 14f * LiveChromeMetrics.scale
    val CAPTURE get() = 64f * LiveChromeMetrics.scale
    val ASSIST get() = 58f * LiveChromeMetrics.scale
    val TOGGLE get() = 40f * LiveChromeMetrics.scale
    val TOGGLE_GAP get() = 8f * LiveChromeMetrics.scale
    val ASSIST_RAIL_EXPANDED get() = 60f * LiveChromeMetrics.scale
    val ASSIST_RAIL_COLLAPSED get() = 44f * LiveChromeMetrics.scale
    val ASSIST_RAIL_EDGE get() = 10f * LiveChromeMetrics.scale
    val REC_OPTIONS get() = 40f * LiveChromeMetrics.scale
    val REC_OPTIONS_INSET get() = 10f * LiveChromeMetrics.scale
    val REC_OPTIONS_GAP get() = 8f * LiveChromeMetrics.scale

    val FIT_BELOW_FEED_SLOT: Float
        get() =
            max(
                TOGGLE_GAP + TOGGLE,
                LiveChromeMetrics.STICK_GAP + LiveChromeMetrics.ZOOM + LiveChromeMetrics.STICK_GAP +
                    LiveChromeMetrics.STICK + LiveChromeMetrics.STICK_INSET,
            )
}

fun portraitZones(
    viewportWidth: Float,
    viewportHeight: Float,
    safeTop: Float,
    safeBottom: Float,
    clean: Boolean,
    fill: Boolean,
    assistToolbarHeight: Float,
    feedAspectRatio: Float = 16f / 9f,
    valueCount: Int? = null,
): PortraitZones {
    val layout = MonitorLayoutPolicy.portrait(
        viewportWidth, viewportHeight, safeTop, safeBottom, fill, !clean, feedAspectRatio, valueCount,
    )
    return PortraitZones(layout.status, layout.picture,
        MonitorRect(0f, layout.controlsFloor, viewportWidth, 0f), layout.values, layout.system)
}

/** Actual visible status row, shared by tap and hold presentation routes. */
fun livePortraitReadoutFrame(layout: LiveMonitorLayout, zones: PortraitZones): MonitorRect =
    MonitorRect(zones.topBar.minX, zones.topBar.minY + 6f, layout.viewportWidth, zones.topBar.height)

/**
 * iOS `LiveViewScreen` fillCrop: landscape fill over-widens a 16:9 picture to
 * the well height, then clips to the well (center crop). Vertical camera fill
 * stays the pillarboxed 9:16 picture and does not use this.
 */
fun portraitFillCropContent(well: MonitorRect): MonitorRect {
    val contentWidth = well.height * 16f / 9f
    return MonitorRect(well.midX - contentWidth / 2f, well.minY, contentWidth, well.height)
}

fun portraitAspectToggle(viewportWidth: Float, floorY: Float): MonitorRect {
    val frame = MonitorLayoutPolicy.portraitAspect(viewportWidth, floorY)
    return MonitorRect(frame.x, frame.y, frame.width, frame.height)
}

fun portraitAssistToolbar(floorY: Float, tablet: Boolean): MonitorRect {
    val frame = MonitorLayoutPolicy.portraitAssists(floorY, tablet)
    return MonitorRect(frame.x, frame.y, frame.width, frame.height)
}

fun portraitOnFeedControls(
    viewportWidth: Float,
    floorY: Float,
    showGimbalButton: Boolean = false,
): GimbalCluster {
    val stickFrame = MonitorLayoutPolicy.portraitStick(viewportWidth, floorY)
    val zoomFrame = MonitorLayoutPolicy.portraitZoom(stickFrame)
    val gimbalFrame = MonitorLayoutPolicy.portraitGimbal(stickFrame, zoomFrame)
    val stick = MonitorRect(stickFrame.x, stickFrame.y, stickFrame.width, stickFrame.height)
    val zoom = MonitorRect(zoomFrame.x, zoomFrame.y, zoomFrame.width, zoomFrame.height)
    val controls =
        if (showGimbalButton) MonitorRect(gimbalFrame.x, gimbalFrame.y, gimbalFrame.width, gimbalFrame.height)
        else MonitorRect(0f, 0f, 0f, 0f)
    return GimbalCluster(stick, zoom, controls)
}
