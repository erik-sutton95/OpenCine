package com.opencapture.opencine.appuitesting

import android.os.SystemClock
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull

/** The shared gallery as the accessibility tree shows it, read from one snapshot per call (Swift twin). */
public class MediaGalleryProbe(private val test: ConformanceTest) {
    public data class Clip(val id: String, val bounds: Box)

    /** The gallery's scrolling viewport, or null while it is not shown. */
    public fun viewport(): Box? = test.snapshot().nodes.firstOrNull { it.visible && it.tag == GALLERY }?.bounds

    /**
     * Clips at least half inside the viewport (their centre is, so a tap lands on them), in reading
     * order. A landscape grid card can be taller than half the viewport, so "wholly inside" could leave
     * no clip at all.
     */
    public fun visibleClips(): List<Clip> {
        val nodes = test.snapshot().nodes
        val viewport = nodes.firstOrNull { it.visible && it.tag == GALLERY }?.bounds ?: return emptyList()
        return nodes.filter {
            it.visible && it.tag?.startsWith(CLIP) == true && !it.bounds.isEmpty &&
                viewport.containsPoint(it.bounds.centerX, it.bounds.centerY)
        }.distinctBy { it.tag }.map { Clip(it.tag!!, it.bounds) }
            .sortedWith(compareBy({ it.bounds.top }, { it.bounds.left }))
    }

    /**
     * Two neighbouring clips (reading order) wholly inside the viewport, for a selection sweep. A clip
     * cut by the viewport's edge sits where a sweep autoscrolls the gallery and widens the selection
     * (a tablet grid's first row under the header). Android reports a node's bounds clipped to what
     * shows, so a card cut by the viewport's edge reads as inside it, only shorter: a pair clip must
     * also have the full card height (the tallest clip in the same snapshot). XCUITest frames are not
     * clipped, so the Swift twin needs only the containment.
     */
    public fun sweepPair(): Pair<Clip, Clip>? {
        val viewport = viewport() ?: return null
        val clips = visibleClips()
        val full = clips.maxOfOrNull { it.bounds.height } ?: return null
        fun whole(clip: Clip) = viewport.contains(clip.bounds) && clip.bounds.height >= full
        return clips.zipWithNext().firstOrNull { (first, second) -> whole(first) && whole(second) }
    }

    /** The first visible clip once the gallery has stopped moving. */
    public fun settledAnchor(timeoutMs: Long = 10_000): Clip? {
        var last: Clip? = null
        var since = SystemClock.uptimeMillis()
        val deadline = since + timeoutMs
        while (SystemClock.uptimeMillis() < deadline) {
            val current = visibleClips().firstOrNull()
            if (current != last) {
                last = current
                since = SystemClock.uptimeMillis()
            } else if (current != null && SystemClock.uptimeMillis() - since >= 600) {
                return current
            }
            test.pause(200)
        }
        return null
    }

    /** The tag of the selected control among `monitor.media.layout.*` or `monitor.media.category.*`. */
    public fun selected(group: String): String? =
        test.snapshot().nodes.firstOrNull { it.visible && it.selected && it.tag?.startsWith("monitor.media.$group.") == true }?.tag

    /** Waits for staged clips, then scrolls the gallery at least two screens down. */
    public fun scrollTwoScreens() {
        test.awaitTag(GALLERY)
        val top = assertNotNull(settledAnchor(), "The staged clips must show")
        repeat(2) { test.swipeUp(assertNotNull(viewport(), "The staged gallery must stay shown")) }
        val scrolled = settledAnchor()
        assertNotNull(scrolled)
        assertNotEquals(top.id, scrolled.id, "Two swipes must move the gallery away from its top")
    }

    public companion object {
        public const val GALLERY: String = "monitor.media.gallery"
        public const val CLIP: String = "monitor.media.clip."
    }
}
