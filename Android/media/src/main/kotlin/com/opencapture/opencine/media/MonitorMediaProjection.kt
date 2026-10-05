package com.opencapture.opencine.media

public enum class MonitorMediaProjectionCategory { ALL, VIDEOS, PHOTOS, FAVORITES }
public enum class MonitorMediaProjectionSort { NEWEST, OLDEST, NAME, RATING }
public enum class MonitorMediaProjectionGroupStage { BEFORE_SORT, AFTER_SORT }
public enum class MonitorMediaProjectionSelectionScope { REPRESENTATIVES, ALL_SURVIVORS }
public enum class MonitorMediaProjectionPairRole { PREFERRED, COMPANION }

public data class MonitorMediaProjectionPair(
    public val identity: String,
    public val role: MonitorMediaProjectionPairRole,
)

/** Captured presentation facts. Missing facts remain unknown; selected filters require a match. */
public data class MonitorMediaProjectionFacts(
    public val id: MediaAssetID,
    public val format: String? = null,
    public val resolution: String? = null,
    public val photoSize: String? = null,
    public val dateWindows: Set<String>? = null,
    public val storageMembership: Set<String>? = null,
    public val pair: MonitorMediaProjectionPair? = null,
    public val localEligible: Boolean? = null,
    public val rating: Int? = null,
)

public data class MonitorMediaProjectionOffered(
    public val formats: List<String> = emptyList(),
    public val resolutions: List<String> = emptyList(),
    public val photoSizes: List<String> = emptyList(),
    public val dateWindows: List<String> = emptyList(),
)

public data class MonitorMediaProjectionCategoryFacts(
    public val rows: List<MonitorMediaProjectionFacts>,
    public val offered: MonitorMediaProjectionOffered = MonitorMediaProjectionOffered(),
)

public data class MonitorMediaProjectionGroup(
    public val representative: MediaAssetID,
    public val members: List<MediaAssetID>,
)

public data class MonitorMediaProjectionRequest(
    public val category: MonitorMediaProjectionCategory = MonitorMediaProjectionCategory.ALL,
    public val sort: MonitorMediaProjectionSort = MonitorMediaProjectionSort.NEWEST,
    public val formats: Set<String> = emptySet(),
    public val resolutions: Set<String> = emptySet(),
    public val photoSizes: Set<String> = emptySet(),
    public val dateWindow: String? = null,
    public val storage: String? = null,
    public val requireLocal: Boolean = false,
    public val selectionScope: MonitorMediaProjectionSelectionScope = MonitorMediaProjectionSelectionScope.REPRESENTATIVES,
)

/** Immutable source policy stages only. The projection owner performs the complete common pipeline. */
public interface MonitorMediaProjectionPolicy {
    public val groupStage: MonitorMediaProjectionGroupStage
    public fun prepareCategory(ids: List<MediaAssetID>, category: MonitorMediaProjectionCategory): MonitorMediaProjectionCategoryFacts
    public fun compare(lhs: MediaAssetID, rhs: MediaAssetID, sort: MonitorMediaProjectionSort): Int
    public fun groups(ids: List<MediaAssetID>): List<MonitorMediaProjectionGroup>
}

/** Payload authority for delayed actions: supplied values stay supplied; members use current values. */
public sealed interface MonitorMediaProjectionExpansionEntry {
    public val id: MediaAssetID
    public data class Supplied(override val id: MediaAssetID) : MonitorMediaProjectionExpansionEntry
    public data class Member(override val id: MediaAssetID) : MonitorMediaProjectionExpansionEntry
}

@ConsistentCopyVisibility
public data class MonitorMediaProjectionResult internal constructor(
    public val categoryIDs: List<MediaAssetID>,
    public val displayIDs: List<MediaAssetID>,
    public val gridIDs: List<MediaAssetID>,
    public val offered: MonitorMediaProjectionOffered,
    public val groups: List<MonitorMediaProjectionGroup>,
) {
    private val groupsByRepresentative = groups.associateBy { it.representative }
    public fun group(id: MediaAssetID): MonitorMediaProjectionGroup? = groupsByRepresentative[id]

    /** Selection reads the same ordered presentation basis used by the caller's visible count. */
    public fun selected(ids: Set<MediaAssetID>): List<MediaAssetID> = displayIDs.filter { it in ids }

    public fun expanded(ids: List<MediaAssetID>): List<MediaAssetID> = expansion(ids).map { it.id }

    /** Expands representatives only. No remaining current members means the supplied value survives. */
    public fun expansion(
        ids: List<MediaAssetID>,
        availableMemberIDs: Set<MediaAssetID>? = null,
    ): List<MonitorMediaProjectionExpansionEntry> {
        val seen = mutableSetOf<MediaAssetID>()
        val result = mutableListOf<MonitorMediaProjectionExpansionEntry>()
        for (id in ids) {
            val members = group(id)?.members?.filter { availableMemberIDs == null || it in availableMemberIDs }.orEmpty()
            if (members.isEmpty()) {
                if (seen.add(id)) result.add(MonitorMediaProjectionExpansionEntry.Supplied(id))
            } else {
                for (member in members) if (seen.add(member)) result.add(MonitorMediaProjectionExpansionEntry.Member(member))
            }
        }
        return result.toList()
    }
}

public object MonitorMediaProjection {
    public fun project(
        ids: List<MediaAssetID>,
        request: MonitorMediaProjectionRequest,
        policy: MonitorMediaProjectionPolicy,
    ): MonitorMediaProjectionResult {
        val admitted = ids.toSet()
        val category = policy.prepareCategory(ids.distinct(), request.category)
        val seen = mutableSetOf<MediaAssetID>()
        val rows = category.rows.filter { it.id in admitted && seen.add(it.id) }
        val filtered = rows.filter { matches(it, request) }
        val preferred = filtered.mapNotNull { row ->
            row.pair?.takeIf { it.role == MonitorMediaProjectionPairRole.PREFERRED }?.identity
        }.toSet()
        val survivors = filtered.filter { row ->
            row.pair?.let { it.role != MonitorMediaProjectionPairRole.COMPANION || it.identity !in preferred } ?: true
        }.map { it.id }
        val ordered: List<MediaAssetID>
        val groups: List<MonitorMediaProjectionGroup>
        when (policy.groupStage) {
            MonitorMediaProjectionGroupStage.BEFORE_SORT -> {
                groups = admitGroups(policy.groups(survivors), survivors)
                ordered = sorted(survivors, request.sort, policy)
            }
            MonitorMediaProjectionGroupStage.AFTER_SORT -> {
                ordered = sorted(survivors, request.sort, policy)
                groups = admitGroups(policy.groups(ordered), ordered)
            }
        }
        val hidden = groups.flatMap { group -> group.members.filter { it != group.representative } }.toSet()
        val grid = ordered.filter { it !in hidden }
        return MonitorMediaProjectionResult(rows.map { it.id },
            if (request.selectionScope == MonitorMediaProjectionSelectionScope.REPRESENTATIVES) grid else ordered,
            grid, category.offered.copy(formats = category.offered.formats.toList(),
                resolutions = category.offered.resolutions.toList(), photoSizes = category.offered.photoSizes.toList(),
                dateWindows = category.offered.dateWindows.toList()), groups)
    }

    /** Stable comparison preserves supplied duplicates and source order when the policy reports a tie. */
    public fun sorted(
        ids: List<MediaAssetID>,
        sort: MonitorMediaProjectionSort,
        policy: MonitorMediaProjectionPolicy,
    ): List<MediaAssetID> = ids.withIndex().sortedWith { left, right ->
        val result = policy.compare(left.value, right.value, sort)
        if (result == 0) left.index.compareTo(right.index) else result
    }.map { it.value }

    private fun matches(row: MonitorMediaProjectionFacts, request: MonitorMediaProjectionRequest): Boolean {
        fun matches(selected: Set<String>, actual: String?): Boolean = selected.isEmpty() || (actual != null && actual in selected)
        return matches(request.formats, row.format) && matches(request.resolutions, row.resolution) &&
            matches(request.photoSizes, row.photoSize) &&
            (request.dateWindow?.let { row.dateWindows?.contains(it) == true } ?: true) &&
            (request.storage?.let { row.storageMembership?.contains(it) == true } ?: true) &&
            (!request.requireLocal || row.localEligible == true)
    }

    private fun admitGroups(
        candidates: List<MonitorMediaProjectionGroup>,
        survivors: List<MediaAssetID>,
    ): List<MonitorMediaProjectionGroup> {
        val admitted = survivors.toSet()
        val claimed = mutableSetOf<MediaAssetID>()
        return candidates.mapNotNull { group ->
            val members = group.members.distinct()
            if (group.representative !in members || members.any { it !in admitted || it in claimed }) null
            else {
                claimed.addAll(members)
                MonitorMediaProjectionGroup(group.representative, members)
            }
        }
    }
}
