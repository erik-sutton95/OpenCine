package com.opencapture.monitorui

/**
 * The picture shapes behind the media grid's staggered (masonry) placement. [MonitorCatalogGrid]
 * puts each card, in the displayed order, into the column that is shortest so far (the leftmost
 * on a tie), and a card is as tall as its picture at the column width plus its caption. The
 * picture's shape comes from metadata known before any thumbnail loads, so loading thumbnails
 * never moves a card. Swift twin: `MonitorMediaMasonry` in MonitorPresentation.
 */
public object MonitorMediaMasonry {
    /** The shape of a picture not known yet: most clips are 16:9. */
    public const val DEFAULT_ASPECT: Double = 16.0 / 9.0
    /** Shapes outside this range (panoramas, slivers) are drawn cropped to it. */
    public const val MIN_ASPECT: Double = 0.5
    public const val MAX_ASPECT: Double = 2.5

    /** A drawable picture shape: unknown or invalid values take [DEFAULT_ASPECT], others are held
     * to [MIN_ASPECT] through [MAX_ASPECT]. */
    public fun aspect(value: Double?): Double {
        if (value == null || !value.isFinite() || value <= 0) return DEFAULT_ASPECT
        return value.coerceIn(MIN_ASPECT, MAX_ASPECT)
    }

    /** Width over height of a picture as it is shown: stored pixel dimensions, turned for an EXIF
     * orientation of 5 to 8 (a quarter turn). Null when the dimensions are unknown. */
    public fun uprightAspect(width: Int?, height: Int?, exifOrientation: Int? = null): Double? {
        if (width == null || height == null || width <= 0 || height <= 0) return null
        return if ((exifOrientation ?: 1) in 5..8) height.toDouble() / width
        else width.toDouble() / height
    }
}
