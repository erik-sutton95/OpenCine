package com.opencapture.opencine.nikon

import com.opencapture.opencine.media.MediaAssetID
import java.time.LocalDate
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/** Goldens moved from OpenZCine's MediaDeletionTest with the plan (A4-35). */
class NikonMediaDeletionPlanTest {
    private val oneBucket: (NikonMediaClipRecord) -> String = { "camera" }

    @Test fun rawSiblingPairsTheSameStemOnTheSameCardOnly() {
        val jpeg = still(1, "DSC_0001.JPG")
        val raw = still(2, "DSC_0001.NEF")
        val otherCardRaw = still(3, "DSC_0001.NEF", storageId = 2)
        val catalog = listOf(jpeg, raw, otherCardRaw, still(4, "DSC_0002.NEF"))
        assertEquals(raw, NikonMediaDeletionPlan.rawSibling(catalog, jpeg, oneBucket))
        assertEquals(raw, NikonMediaDeletionPlan.rawSibling(catalog, still(1, "dsc_0001.jpg"), oneBucket))
        assertNull(NikonMediaDeletionPlan.rawSibling(catalog, raw, oneBucket))
        assertNull(NikonMediaDeletionPlan.rawSibling(catalog, still(5, "C0001.MOV"), oneBucket))
        assertNull(NikonMediaDeletionPlan.rawSibling(listOf(jpeg, otherCardRaw), jpeg, oneBucket))
    }

    @Test fun pairKeyScopesFormulaicStemsToTheOwningBucket() {
        val jpeg = still(1, "DSC_0001.JPG")
        val foreignRaw = still(2, "DSC_0001.NEF")
        val owners = mapOf(1L to "camera-a", 2L to "camera-b")
        assertNull(NikonMediaDeletionPlan.rawSibling(listOf(jpeg, foreignRaw), jpeg) { owners.getValue(it.handle) })
        assertEquals(foreignRaw, NikonMediaDeletionPlan.rawSibling(listOf(jpeg, foreignRaw), jpeg, oneBucket))
        assertEquals("camera/7/dsc_0001", NikonMediaDeletionPlan.pairKey("camera", still(3, "DSC_0001.JPG", storageId = 7)))
    }

    @Test fun galleryRawCompanionAndDeletionShareThePairRule() {
        val clips = listOf(still(1, "DSC_0001.JPG"), still(2, "DSC_0001.NEF"), still(3, "DSC_0001.NEF", storageId = 2),
            still(4, "DSC_0002.JPG"), still(5, "dsc_0002.nef"), still(6, "C0001.MOV"))
        val items = clips.map { NikonGallerySourceItem(MediaAssetID("id-${it.handle}"), "${it.handle}", "camera", it, false) }
        val policy = NikonAndroidGalleryProjectionPolicy(items, LocalDate.of(2026, 7, 14))
        items.forEach { item ->
            assertEquals(NikonMediaDeletionPlan.rawSibling(clips, item.clip, oneBucket)?.let { MediaAssetID("id-${it.handle}") },
                policy.rawCompanion(item.id))
        }
    }

    @Test fun targetsExpandPairsOnceAndKeepRawOnlySelectionsNarrow() {
        val jpeg = still(1, "DSC_0001.JPG")
        val raw = still(2, "DSC_0001.NEF")
        val movie = still(3, "C0001.MOV")
        val catalog = listOf(jpeg, raw, movie)
        assertEquals(listOf(jpeg, raw), NikonMediaDeletionPlan.of(catalog, listOf(jpeg), oneBucket).targets)
        assertEquals(listOf(jpeg, raw), NikonMediaDeletionPlan.of(catalog, listOf(jpeg, raw), oneBucket).targets)
        assertEquals(listOf(raw), NikonMediaDeletionPlan.of(catalog, listOf(raw), oneBucket).targets)
        assertEquals(listOf(movie), NikonMediaDeletionPlan.of(catalog, listOf(movie), oneBucket).targets)
    }

    @Test fun deletionWidensToCrossCardBackupTwins() {
        val jpeg = still(1, "DSC_0001.JPG")
        val raw = still(2, "DSC_0001.NEF")
        val backupJpeg = still(21, "DSC_0001.JPG", storageId = 2)
        val backupRaw = still(22, "DSC_0001.NEF", storageId = 2)
        val bystander = still(3, "DSC_0002.JPG", captureDate = "20260714T110000")
        val plan = NikonMediaDeletionPlan.of(listOf(jpeg, raw, backupJpeg, backupRaw, bystander), listOf(jpeg), oneBucket)
        assertEquals(setOf(jpeg, raw, backupJpeg, backupRaw), plan.targets.toSet())
        assertEquals(1, plan.pairCount)
        assertEquals(2, plan.backupCount)
    }

    @Test fun deletingAProxyTakesItsHiddenCameraMaster() {
        val proxy = still(5, "A001_0001.MP4")
        val master = still(6, "A001_0001.NEV")
        val plan = NikonMediaDeletionPlan.of(listOf(proxy, master, still(7, "A001_0002.MP4", captureDate = "20260714T111000")),
            listOf(proxy), oneBucket)
        assertEquals(listOf(proxy, master), plan.targets)
        assertEquals(1, plan.masterCount)
        assertEquals(0, plan.pairCount)
    }

    @Test fun undatedClipsNeverTwin() {
        val jpeg = still(1, "DSC_0003.JPG", captureDate = "")
        val plan = NikonMediaDeletionPlan.of(listOf(jpeg, still(2, "DSC_0003.NEF", storageId = 2, captureDate = "")),
            listOf(jpeg), oneBucket)
        assertEquals(listOf(jpeg), plan.targets)
        assertEquals(0, plan.backupCount)
    }

    /** The still label agrees with the extension, as the listing wire's shared-core classification does. */
    private fun still(handle: Long, filename: String, storageId: Long = 1, captureDate: String = "20260714T101010"): NikonMediaClipRecord {
        val extension = filename.substringAfterLast('.').lowercase()
        val kind = when (extension) {
            "mov", "mp4" -> NikonMediaContentKind.PLAYABLE_PROXY
            "r3d" -> NikonMediaContentKind.R3D_MASTER
            "nev" -> NikonMediaContentKind.UNSUPPORTED
            else -> NikonMediaContentKind.STILL_PHOTO
        }
        val label = when (extension) { "nef", "nrw", "dng" -> "NEF"; "hif", "heif", "heic" -> "HEIF"; else -> "JPEG" }
        return NikonMediaClipRecord(handle, storageId, 100, captureDate, 3840, 2160, filename, kind,
            if (kind == NikonMediaContentKind.STILL_PHOTO) NikonStillPhotoClassification(label, NikonStillPreviewStrategy.PROGRESSIVE) else null)
    }
}
