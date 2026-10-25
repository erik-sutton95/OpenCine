package com.opencapture.opencine.nikon

import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MonitorMediaProjectionCategory
import com.opencapture.opencine.media.MonitorMediaProjectionCategoryFacts
import java.time.LocalDate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * SIMULATED 3200-object card (1500 NEF+JPEG pairs, 200 clips). The filter offer ranked the still
 * widths again for every photo and every size key, O(photos^2 log photos) per category pass, and
 * the gallery runs one pass per category count on every listing change.
 */
class NikonGalleryProjectionPerformanceTest {
    private fun still(name: String, format: String, width: Int, minute: Int) = NikonMediaClipRecord(
        handle = name.hashCode().toLong() and 0xFFFF_FFFFL, storageId = 1, sizeBytes = 12_000_000,
        captureDate = "20261025T%02d%02d00".format(minute / 60 % 24, minute % 60),
        pixelWidth = width, pixelHeight = width * 2 / 3, filename = name,
        contentKind = NikonMediaContentKind.STILL_PHOTO,
        stillPhoto = NikonStillPhotoClassification(format, NikonStillPreviewStrategy.PROGRESSIVE))

    private fun card(pairs: Int, clips: Int) = buildList {
        for (index in 0 until pairs) {
            val stem = "DSC_%04d".format(index + 1)
            val width = listOf(6048, 4528, 3024)[index % 3]
            add(still("$stem.NEF", "NEF", width, index)); add(still("$stem.JPG", "JPEG", width, index))
        }
        for (index in 0 until clips) add(NikonMediaClipRecord(handle = 900_000L + index, storageId = 1, sizeBytes = 900_000_000,
            captureDate = "20261025T120000", pixelWidth = 3840, pixelHeight = 2160, filename = "DSC_%04d.MOV".format(1501 + index),
            contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null))
    }.map { NikonGallerySourceItem(MediaAssetID(it.filename), it.filename, "bucket", it, false) }
    private val items = card(1500, 200)

    /** Best of several timed runs: a hosted runner's GC pauses and noisy neighbours only add time. */
    private fun bestMillis(runs: Int, body: () -> Unit): Double {
        body() // warm the JIT
        return (1..runs).minOf { val started = System.nanoTime(); body(); (System.nanoTime() - started) / 1e6 }
    }

    /** Doubling the card must roughly double the passes (quadratic ranking quadrupled them). The
     *  ratio does not depend on the runner's speed, unlike a wall-clock budget. */
    @Test fun fourCategoryPassesOverALargeCardStayLinear() {
        fun passes(items: List<NikonGallerySourceItem>): Pair<Double, List<MonitorMediaProjectionCategoryFacts>> {
            val policy = NikonAndroidGalleryProjectionPolicy(items, LocalDate.of(2026, 10, 25))
            val ids = items.map { it.id }
            fun run() = MonitorMediaProjectionCategory.entries.map { policy.prepareCategory(ids, it) }
            return bestMillis(3) { run() } to run()
        }
        val (half, _) = passes(card(750, 100))
        val (full, facts) = passes(items)
        println("MEDIA-PERF-ANDROID nikon.fourCategoryPasses.ms: half $half, full $full")
        assertEquals(listOf("L", "M", "S"), facts.first { it.rows.size == 3000 }.offered.photoSizes)
        assertTrue(full / half.coerceAtLeast(1.0) < 3.0, "doubling the card took ${full / half}x ($half to $full ms)")
    }

    /** Every visible JPEG cell asks for its RAW partner on each composition. A lookup that scans the
     *  card makes all lookups quadratic: doubling the card quadruples them. */
    @Test fun rawCompanionLookupsDoNotScanTheCard() {
        val policy = NikonAndroidGalleryProjectionPolicy(items, LocalDate.of(2026, 10, 25))
        assertEquals(MediaAssetID("DSC_0001.NEF"), policy.rawCompanion(MediaAssetID("DSC_0001.JPG")))
        assertEquals(null, policy.rawCompanion(MediaAssetID("DSC_0001.NEF")))
        assertEquals(1500, items.count { it.clip.filename.endsWith(".JPG") && policy.rawCompanion(it.id) != null })
        fun lookups(card: List<NikonGallerySourceItem>): Double {
            val policy = NikonAndroidGalleryProjectionPolicy(card, LocalDate.of(2026, 10, 25))
            val jpegs = card.filter { it.clip.filename.endsWith(".JPG") }.map { it.id }
            return bestMillis(5) { repeat(20) { jpegs.forEach { policy.rawCompanion(it) } } }
        }
        val half = lookups(card(750, 100))
        val full = lookups(items)
        println("MEDIA-PERF-ANDROID nikon.rawCompanion.ms: half $half, full $full")
        assertTrue(full / half.coerceAtLeast(1.0) < 3.0, "doubling the card took ${full / half}x ($half to $full ms)")
    }
}
