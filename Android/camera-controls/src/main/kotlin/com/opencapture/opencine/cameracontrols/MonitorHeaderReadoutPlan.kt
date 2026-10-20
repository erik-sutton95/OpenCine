package com.opencapture.opencine.cameracontrols

import com.opencapture.opencine.appkit.MonitorOperatorLiveReadout
import com.opencapture.opencine.vocabulary.MonitorHeaderAccent

/**
 * The status row's readouts after the colour fold: one codec control carries the colour in its
 * popup, as portrait already does, and a camera without a codec readout keeps its own colour
 * readout and target. Values only, never a brand test. Swift twin: `MonitorHeaderReadoutPlan`.
 */
public class MonitorHeaderReadoutPlan<K, S>(
    public val format: List<MonitorOperatorLiveReadout<K, S>>,
    /** The separate colour readout the header still shows, when the colour did not fold. */
    public val color: MonitorOperatorLiveReadout<K, S>?,
    /** The colour readout the codec control absorbed, when the fold happened. */
    public val foldedColor: MonitorOperatorLiveReadout<K, S>?,
    /**
     * The landscape codec control that also speaks the folded colour. Portrait keeps its spoken
     * codec value, as it already showed it.
     */
    public val combined: MonitorHeaderCombinedCodec<K, S>?,
    /**
     * The readout that carries the accent: the declared slot, only while the header shows it.
     * Null otherwise; the accent never moves to another readout.
     */
    public val accented: K?,
) {
    public val foldsColor: Boolean get() = foldedColor != null

    /**
     * The codec readout speaks both reported values, so the colour is still announced after its
     * own target disappears. Null for every other readout and when the colour stays separate.
     */
    public fun accessibility(value: MonitorOperatorLiveReadout<K, S>): Pair<String, String>? =
        combined?.takeIf { it.codec.id == value.id }?.let { it.title to it.value }
}

/**
 * The one codec control that carries the colour: the shown value stays the codec, while the
 * spoken value covers both. Swift twin: `MonitorHeaderCombinedCodec`.
 */
public class MonitorHeaderCombinedCodec<K, S>(
    public val codec: MonitorOperatorLiveReadout<K, S>,
    public val color: MonitorOperatorLiveReadout<K, S>,
) {
    public val title: String get() = MonitorHeaderReadoutPolicy.COMBINED_CODEC_TITLE
    /** The separator is the one the apps use for combined values (`6K · 25p`). */
    public val value: String get() = "${codec.value ?: "--"} · ${color.value ?: "--"}"
}

public object MonitorHeaderReadoutPolicy {
    /** The one spoken title for a combined codec control. */
    public const val COMBINED_CODEC_TITLE: String = "Codec and color"

    /**
     * The status row's mounted format readouts and the separate colour readout. Portrait and
     * landscape both fold colour into a codec readout; portrait photography keeps its existing
     * stack because its quality readout is not the video codec. Landscape also speaks both
     * values from the one control.
     */
    public fun <K, S> plan(
        format: List<MonitorOperatorLiveReadout<K, S>>,
        color: MonitorOperatorLiveReadout<K, S>?,
        mode: MonitorOperatorLiveReadout<K, S>?,
        accent: MonitorHeaderAccent,
        portrait: Boolean, photo: Boolean,
        // The live body is generic over its section type; the codec section is matched by equality.
        mounted: Set<S>, codecSection: Any,
    ): MonitorHeaderReadoutPlan<K, S> {
        fun shown(section: S?): Boolean = section?.let { it in mounted } ?: true
        val shownFormat = format.filter { shown(it.section) }
        val shownColor = color?.takeIf { shown(it.section) }
        val codec = shownFormat.firstOrNull { it.section == codecSection }
        val foldedColor = if (!(portrait && photo) && codec != null) shownColor else null
        val combined = if (!portrait && foldedColor != null && codec != null)
            MonitorHeaderCombinedCodec(codec, foldedColor) else null
        val accented = when (accent) {
            MonitorHeaderAccent.SHOOTING_MODE -> mode?.id
            MonitorHeaderAccent.CODEC -> codec?.id
        }
        return MonitorHeaderReadoutPlan(shownFormat, if (foldedColor == null) shownColor else null,
            foldedColor, combined, accented)
    }
}
