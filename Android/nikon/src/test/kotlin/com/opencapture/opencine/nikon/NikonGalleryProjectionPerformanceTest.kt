package com.opencapture.opencine.nikon

import com.opencapture.opencine.media.MediaAssetID
import com.opencapture.opencine.media.MonitorMediaProjectionCategory
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

    private val items = buildList {
        for (index in 0 until 1500) {
            val stem = "DSC_%04d".format(index + 1)
            val width = listOf(6048, 4528, 3024)[index % 3]
            add(still("$stem.NEF", "NEF", width, index)); add(still("$stem.JPG", "JPEG", width, index))
        }
        for (index in 0 until 200) add(NikonMediaClipRecord(handle = 900_000L + index, storageId = 1, sizeBytes = 900_000_000,
            captureDate = "20261025T120000", pixelWidth = 3840, pixelHeight = 2160, filename = "DSC_%04d.MOV".format(1501 + index),
            contentKind = NikonMediaContentKind.PLAYABLE_PROXY, stillPhoto = null))
    }.map { NikonGallerySourceItem(MediaAssetID(it.filename), it.filename, "bucket", it, false) }

    @Test fun fourCategoryPassesOverALargeCardStayLinear() {
        val policy = NikonAndroidGalleryProjectionPolicy(items, LocalDate.of(2026, 10, 25))
        val ids = items.map { it.id }
        fun run() = MonitorMediaProjectionCategory.entries.map { policy.prepareCategory(ids, it) }
        run() // warm the JIT
        val started = System.nanoTime()
        val facts = run()
        val millis = (System.nanoTime() - started) / 1_000_000
        println("MEDIA-PERF-ANDROID nikon.fourCategoryPasses.ms: $millis")
        assertEquals(listOf("L", "M", "S"), facts.first { it.rows.size == 3000 }.offered.photoSizes)
        assertTrue(millis < 250, "four category passes took $millis ms for ${items.size} objects")
    }

    /** Every visible JPEG cell asks for its RAW partner on each composition. */
    @Test fun rawCompanionLookupsDoNotScanTheCard() {
        val policy = NikonAndroidGalleryProjectionPolicy(items, LocalDate.of(2026, 10, 25))
        val jpegs = items.filter { it.clip.filename.endsWith(".JPG") }
        assertEquals(MediaAssetID("DSC_0001.NEF"), policy.rawCompanion(MediaAssetID("DSC_0001.JPG")))
        assertEquals(null, policy.rawCompanion(MediaAssetID("DSC_0001.NEF")))
        jpegs.forEach { policy.rawCompanion(it.id) } // warm the JIT
        val started = System.nanoTime()
        val paired = jpegs.count { policy.rawCompanion(it.id) != null }
        val millis = (System.nanoTime() - started) / 1_000_000
        println("MEDIA-PERF-ANDROID nikon.rawCompanion.1500.ms: $millis")
        assertEquals(1500, paired)
        assertTrue(millis < 15, "1500 RAW partner lookups took $millis ms")
    }
}
