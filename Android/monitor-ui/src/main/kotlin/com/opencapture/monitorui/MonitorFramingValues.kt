package com.opencapture.monitorui

enum class MonitorGuideFamily(val label: String) {
    FILM("Film"),
    SOCIAL("Social"),
    ;

    companion object {
        fun fromPersisted(raw: String): MonitorGuideFamily =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: FILM
    }
}

enum class MonitorGuideAspect(val label: String) {
    CINEMA_276("2.76:1"),
    CINEMA("2.39:1"),
    CINEMA_235("2.35:1"),
    TWO_K("2.00:1"),
    WIDE("1.85:1"),
    HD("16:9"),
    EURO("1.66:1"),
    IMAX("1.43:1"),
    ACADEMY("4:3"),
    VERTICAL("9:16"),
    SOCIAL("4:5"),
    SQUARE("1:1"),
    PORTRAIT("2:3"),
    FEED("1.91:1"),
    ;

    val ratio: Float
        get() {
            val parts = label.split(':')
            val a = parts.getOrNull(0)?.toFloatOrNull() ?: return 1f
            val b = parts.getOrNull(1)?.toFloatOrNull() ?: return 1f
            return if (b > 0f) a / b else 1f
        }

    companion object {
        val film: List<MonitorGuideAspect> =
            listOf(CINEMA_276, CINEMA, CINEMA_235, TWO_K, WIDE, HD, EURO, IMAX, ACADEMY)
        val social: List<MonitorGuideAspect> = listOf(VERTICAL, SOCIAL, SQUARE, PORTRAIT, HD, FEED)

        fun ratios(family: MonitorGuideFamily): List<MonitorGuideAspect> =
            when (family) {
                MonitorGuideFamily.FILM -> film
                MonitorGuideFamily.SOCIAL -> social
            }

        fun fromPersisted(raw: String): MonitorGuideAspect =
            entries.firstOrNull { it.label == raw || it.name == raw } ?: CINEMA
    }
}

/** Which selected frame area stays clear when the optional guide mask is enabled. */
enum class MonitorGuideMaskPolicy {
    /** Keep the union of the actual selected frame rectangles clear. */
    UNION,
    /** Keep their bounding rectangle clear, including space between crossing frames. */
    ENVELOPE,
}

data class MonitorGridSegment(val from: MonitorScopePoint, val to: MonitorScopePoint)

object MonitorGridGeometry {
    val thirdsFractions = listOf(1f / 3f, 2f / 3f)
    val phiFractions = listOf(0.382f, 0.618f)
    const val STROKE_OPACITY = 0.22f
    const val STROKE_WIDTH_DP = 1f
    val optionLabels = listOf("Thirds", "Phi Grid", "Diagonal")

    fun segments(
        feed: MonitorScopeRect,
        thirds: Boolean,
        phi: Boolean,
        diagonal: Boolean,
    ): List<MonitorGridSegment> {
        val lines = ArrayList<MonitorGridSegment>(12)
        if (thirds) appendFractions(feed, thirdsFractions, lines)
        if (phi) appendFractions(feed, phiFractions, lines)
        if (diagonal) {
            lines +=
                MonitorGridSegment(
                    MonitorScopePoint(feed.minX, feed.minY),
                    MonitorScopePoint(feed.maxX, feed.maxY),
                )
            lines +=
                MonitorGridSegment(
                    MonitorScopePoint(feed.maxX, feed.minY),
                    MonitorScopePoint(feed.minX, feed.maxY),
                )
        }
        return lines
    }

    private fun appendFractions(feed: MonitorScopeRect, fractions: List<Float>, lines: MutableList<MonitorGridSegment>) {
        for (fraction in fractions) {
            val x = feed.minX + feed.width * fraction
            val y = feed.minY + feed.height * fraction
            lines += MonitorGridSegment(MonitorScopePoint(x, feed.minY), MonitorScopePoint(x, feed.maxY))
            lines += MonitorGridSegment(MonitorScopePoint(feed.minX, y), MonitorScopePoint(feed.maxX, y))
        }
    }
}

object MonitorGuideGeometry {
    /** Letterbox when the guide is wider than the feed, pillarbox when narrower. */
    fun rectForRatio(feed: MonitorScopeRect, ratio: Float): MonitorScopeRect {
        val width: Float
        val height: Float
        if (feed.height <= 0f || ratio <= 0f) return feed
        if (feed.width / feed.height > ratio) {
            height = feed.height
            width = feed.height * ratio
        } else {
            width = feed.width
            height = feed.width / ratio
        }
        return MonitorScopeRect(
            feed.minX + (feed.width - width) / 2f,
            feed.minY + (feed.height - height) / 2f,
            width,
            height,
        )
    }
}

object MonitorCrosshairGeometry {
    const val ARM_LENGTH_DP = 40f
    const val STROKE_WIDTH_DP = 1.4f
    const val OPACITY = 0.65f
    const val HELP = "Tap the toolbar button to show or hide the centre crosshair."
}

/** One safe area drawn inside every frame line. */
enum class MonitorGuideSafeAreaKind(val title: String, val help: String) {
    ACTION(
        "Action safe",
        "A dashed line inside each frame line. Keep the action inside it to leave room to stabilize or reframe.",
    ),
    TITLE("Title safe", "A dotted line inside each frame line for text and graphics."),
}

/** A safe area that is switched on, with its share of the frame line. */
data class MonitorGuideSafeArea(val kind: MonitorGuideSafeAreaKind, val percent: Int)

/**
 * Action safe and title safe lines inside each drawn frame line. Each is a centred share of the
 * frame line's width and height, so 90% leaves 5% of the frame clear on every side. Both start
 * off at 90% and 80%. Mirrors Swift `MonitorGuideSafeAreas`.
 */
data class MonitorGuideSafeAreas(
    val actionSafe: Boolean = false,
    val actionPercent: Int = STANDARD_ACTION_PERCENT,
    val titleSafe: Boolean = false,
    val titlePercent: Int = STANDARD_TITLE_PERCENT,
) {
    fun isOn(kind: MonitorGuideSafeAreaKind): Boolean =
        if (kind == MonitorGuideSafeAreaKind.ACTION) actionSafe else titleSafe

    /** The share of the frame line, clamped to [MIN_PERCENT]..[MAX_PERCENT]. */
    fun percent(kind: MonitorGuideSafeAreaKind): Int =
        clamped(if (kind == MonitorGuideSafeAreaKind.ACTION) actionPercent else titlePercent)

    fun withOn(kind: MonitorGuideSafeAreaKind, on: Boolean): MonitorGuideSafeAreas =
        if (kind == MonitorGuideSafeAreaKind.ACTION) copy(actionSafe = on) else copy(titleSafe = on)

    fun withPercent(kind: MonitorGuideSafeAreaKind, percent: Int): MonitorGuideSafeAreas =
        if (kind == MonitorGuideSafeAreaKind.ACTION) copy(actionPercent = clamped(percent))
        else copy(titlePercent = clamped(percent))

    /** The safe areas to draw, action safe first. */
    val drawn: List<MonitorGuideSafeArea>
        get() = MonitorGuideSafeAreaKind.entries.filter(::isOn).map { MonitorGuideSafeArea(it, percent(it)) }

    companion object {
        const val MIN_PERCENT: Int = 50
        const val MAX_PERCENT: Int = 99
        const val STANDARD_ACTION_PERCENT: Int = 90
        const val STANDARD_TITLE_PERCENT: Int = 80
        val STANDARD: MonitorGuideSafeAreas = MonitorGuideSafeAreas()
        const val SIZE_HELP: String = "Share of the frame line's width and height, from 50% to 99%."

        fun label(percent: Int): String = "$percent%"

        fun clamped(percent: Int): Int = percent.coerceIn(MIN_PERCENT, MAX_PERCENT)

        /** The centred [percent] share of [frame]'s width and height. */
        fun inset(frame: MonitorScopeRect, percent: Int): MonitorScopeRect {
            val share = clamped(percent) / 100f
            val width = frame.width * share
            val height = frame.height * share
            return MonitorScopeRect(
                frame.minX + (frame.width - width) / 2f,
                frame.minY + (frame.height - height) / 2f,
                width,
                height,
            )
        }
    }
}
