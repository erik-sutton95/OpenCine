package com.opencapture.opencine.nikon

import com.opencapture.opencine.media.*
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.Locale

/** Captured actual row and echoed identities; no route/cache address is extracted from id. */
public data class NikonGallerySourceItem(
    val id: MediaAssetID,
    val legacyID: String,
    val namespace: String,
    val clip: NikonMediaClipRecord,
    val favorite: Boolean,
)

/** Exact source stages; the neutral owner implements filtering, pairs, ordering and selection. */
public class NikonAndroidGalleryProjectionPolicy(
    private val items: List<NikonGallerySourceItem>,
    private val today: LocalDate,
) : MonitorMediaProjectionPolicy {
    override val groupStage = MonitorMediaProjectionGroupStage.AFTER_SORT
    private val byID = items.associateBy { it.id }
    override fun prepareCategory(ids: List<MediaAssetID>, category: MonitorMediaProjectionCategory): MonitorMediaProjectionCategoryFacts {
        val scoped = ids.mapNotNull(byID::get).filter { item ->
            when (category) {
                MonitorMediaProjectionCategory.ALL -> true
                MonitorMediaProjectionCategory.VIDEOS -> item.clip.contentKind == NikonMediaContentKind.PLAYABLE_PROXY || item.clip.contentKind == NikonMediaContentKind.R3D_MASTER
                MonitorMediaProjectionCategory.PHOTOS -> item.clip.contentKind == NikonMediaContentKind.STILL_PHOTO
                MonitorMediaProjectionCategory.FAVORITES -> item.favorite
            }
        }
        val widths = scoped.filter { it.clip.contentKind == NikonMediaContentKind.STILL_PHOTO }
            .map { it.clip.pixelWidth }.filter { it > 0 }.distinct().sortedDescending()
        val rows = scoped.map { item ->
            val clip = item.clip
            val photo = clip.contentKind == NikonMediaContentKind.STILL_PHOTO
            val size = if (!photo || clip.pixelWidth <= 0 || widths.size > 3) null
                else listOf("L", "M", "S").getOrNull(widths.indexOf(clip.pixelWidth))
            val format = format(clip)
            val day = captureDay(clip.captureDate)
            val windows = day?.let { value -> dayWindows.filter { (_, count) ->
                !value.isAfter(today) && !value.isBefore(today.minusDays(count - 1))
            }.mapTo(linkedSetOf()) { it.first } }
            MonitorMediaProjectionFacts(id = item.id, format = format,
                resolution = resolution(clip), photoSize = size,
                dateWindows = windows, storageMembership = setOf(clip.storageId.toString()),
                pair = when (format) {
                    "JPEG" -> MonitorMediaProjectionPair(pairKey(item), MonitorMediaProjectionPairRole.PREFERRED)
                    "NEF" -> MonitorMediaProjectionPair(pairKey(item), MonitorMediaProjectionPairRole.COMPANION)
                    else -> null
                }, localEligible = null, rating = null)
        }
        return MonitorMediaProjectionCategoryFacts(rows, offered(scoped.map { it.clip }, today))
    }

    /** RATING is the shared library order: favorites first, then newest. */
    override fun compare(lhs: MediaAssetID, rhs: MediaAssetID, sort: MonitorMediaProjectionSort): Int {
        val left = byID[lhs] ?: return 0
        val right = byID[rhs] ?: return 0
        if (sort == MonitorMediaProjectionSort.RATING && left.favorite != right.favorite) return if (left.favorite) -1 else 1
        return compareClips(left.clip, right.clip, sort)
    }
    override fun groups(ids: List<MediaAssetID>): List<MonitorMediaProjectionGroup> {
        val survivors = ids.mapNotNull(byID::get)
        val IDsByLegacy = survivors.associate { it.legacyID to it.id }
        val frames = survivors.map { item ->
            val clip = item.clip
            BurstFrame(item.legacyID, clip.storageId, clip.handle, clip.captureDate,
                clip.filename.substringBeforeLast('.').lowercase(Locale.US), format(clip) == "NEF",
                "${clip.filename.substringAfterLast('.', "").lowercase(Locale.US)}|${clip.pixelWidth}x${clip.pixelHeight}")
        }
        return BurstSeriesGrouping.group(frames).mapNotNull { run ->
            val representative = IDsByLegacy[run.representativeID] ?: return@mapNotNull null
            MonitorMediaProjectionGroup(representative, run.memberIDs.mapNotNull(IDsByLegacy::get))
        }
    }
    /** The unchanged viewer/deletion widening looks through the full captured bucket. */
    public fun rawCompanion(id: MediaAssetID): MediaAssetID? {
        val item = byID[id] ?: return null
        if (formatKey(item.clip) != "JPEG") return null
        return rawByPairKey[pairKey(item)]?.id
    }
    /** The first RAW per pair key, as rawPartner's scan would find it; a cell asks in O(1). */
    private val rawByPairKey: Map<String, NikonGallerySourceItem> by lazy {
        HashMap<String, NikonGallerySourceItem>().also { map ->
            items.forEach { if (formatKey(it.clip) == "NEF") map.putIfAbsent(pairKey(it), it) }
        }
    }
    private fun pairKey(item: NikonGallerySourceItem): String = NikonMediaDeletionPlan.pairKey(item.namespace, item.clip)
    public companion object {
        public fun compareClips(left: NikonMediaClipRecord, right: NikonMediaClipRecord, sort: MonitorMediaProjectionSort): Int {
        val names = left.filename.lowercase(Locale.US).compareTo(right.filename.lowercase(Locale.US))
        return when (sort) {
            MonitorMediaProjectionSort.NAME -> names
            // A clip carries no favorite; the policy orders favorites first and ties fall to newest.
            MonitorMediaProjectionSort.NEWEST, MonitorMediaProjectionSort.RATING -> right.captureDate.ifEmpty { right.filename }
                .compareTo(left.captureDate.ifEmpty { left.filename }).takeIf { it != 0 } ?: -names
            MonitorMediaProjectionSort.OLDEST -> left.captureDate.ifEmpty { left.filename }
                .compareTo(right.captureDate.ifEmpty { right.filename }).takeIf { it != 0 } ?: names
        }
        }
        public fun formatKey(clip: NikonMediaClipRecord): String? = format(clip)
        public fun resolutionKey(clip: NikonMediaClipRecord): String? = resolution(clip)
        public fun stillWidths(clips: List<NikonMediaClipRecord>): List<Int> =
            clips.filter { it.contentKind == NikonMediaContentKind.STILL_PHOTO }.map { it.pixelWidth }
        public fun photoSizeKey(clip: NikonMediaClipRecord, widths: List<Int>): String? =
            rankedPhotoSizeKey(clip, photoSizeRanking(widths))
        /** The L/M/S ranking of a listing's still widths, built once per listing (not per photo). */
        public fun photoSizeRanking(widths: List<Int>): List<Int> = widths.filter { it > 0 }.distinct().sortedDescending()
        private fun rankedPhotoSizeKey(clip: NikonMediaClipRecord, ranked: List<Int>): String? {
            if (clip.contentKind != NikonMediaContentKind.STILL_PHOTO || clip.pixelWidth <= 0) return null
            if (ranked.size > 3) return null
            return listOf("L", "M", "S").getOrNull(ranked.indexOf(clip.pixelWidth))
        }
        public fun windowContains(date: String, dayCount: Long, today: LocalDate): Boolean {
            val day = captureDay(date) ?: return false
            return !day.isAfter(today) && !day.isBefore(today.minusDays(dayCount - 1))
        }
        public fun offered(clips: List<NikonMediaClipRecord>, today: LocalDate): MonitorMediaProjectionOffered {
            // One key per clip per facet, then counts: O(n) per listing, not O(n) per candidate per clip.
            fun offered(candidates: List<String>, keys: (NikonMediaClipRecord) -> Collection<String>): List<String> {
                val counts = HashMap<String, Int>()
                clips.forEach { clip -> keys(clip).forEach { counts[it] = (counts[it] ?: 0) + 1 } }
                return candidates.filter { (counts[it] ?: 0) in 1 until clips.size }
            }
            val ranked = photoSizeRanking(stillWidths(clips))
            val days = HashMap<String, LocalDate?>()
            return MonitorMediaProjectionOffered(
                formats = offered(formats) { clip -> listOfNotNull(format(clip)) },
                resolutions = offered(listOf("HD", "4K", "5.4K", "6K")) { clip ->
                    if (clip.contentKind != NikonMediaContentKind.STILL_PHOTO) listOfNotNull(resolution(clip)) else emptyList() },
                photoSizes = offered(listOf("L", "M", "S")) { clip -> listOfNotNull(rankedPhotoSizeKey(clip, ranked)) },
                dateWindows = offered(dayWindows.map { it.first }) { clip ->
                    val day = days.getOrPut(clip.captureDate.take(8)) { captureDay(clip.captureDate) } ?: return@offered emptyList()
                    dayWindows.filter { (_, count) -> !day.isAfter(today) && !day.isBefore(today.minusDays(count - 1)) }.map { it.first }
                })
        }
        private fun format(clip: NikonMediaClipRecord): String? = clip.stillPhoto?.formatLabel?.takeIf { it in formats }
        ?: when (clip.codecLabel) { "MOV", "M4V" -> "MOV"; "MP4" -> "MP4"; else -> null }
        private fun resolution(clip: NikonMediaClipRecord): String? = resolution(clip.sourcePixelWidth)
        ?: resolution(clip.pixelWidth) ?: resolution(clip.filename)
        private fun resolution(width: Int): String? = when (width) {
        in 6_000..Int.MAX_VALUE -> "6K"; in 5_300..<6_000 -> "5.4K"; in 3_500..<5_300 -> "4K"; in 1_000..<3_500 -> "HD"; else -> null
    }
        private fun resolution(filename: String): String? {
        val upper = filename.uppercase(Locale.US)
        return when { upper.contains("6K") -> "6K"; upper.contains("5.4K") || upper.contains("54K") -> "5.4K";
            upper.contains("4K") || upper.contains("UHD") -> "4K"; upper.contains("HD") || upper.contains("1080") -> "HD"; else -> null }
    }
        private fun captureDay(date: String): LocalDate? {
        val token = date.take(8)
        if (token.length != 8 || !token.all { it in '0'..'9' }) return null
        return try { LocalDate.parse(token, DateTimeFormatter.BASIC_ISO_DATE) }
        catch (_: DateTimeParseException) { null }
    }
        private val formats = listOf("MOV", "MP4", "JPEG", "HEIF", "NEF", "TIFF", "PNG")
        private val dayWindows = listOf("TODAY" to 1L, "7 DAYS" to 7L, "30 DAYS" to 30L)
    }
}
