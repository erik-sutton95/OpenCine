package com.opencapture.opencine.media

import kotlin.test.*

class MonitorMediaProjectionTest {
    private val a = MediaAssetID("a")
    private val b = MediaAssetID("b")
    private val c = MediaAssetID("c")
    private val d = MediaAssetID("d")

    @Test fun unknownFactsSurviveWithoutSelectionsAndSelectedGroupsRequireKnownMatches() {
        val policy = Policy(listOf(
            MonitorMediaProjectionFacts(a),
            MonitorMediaProjectionFacts(b, format = "MOV", resolution = "4K", photoSize = "large",
                dateWindows = setOf("today"), storageMembership = setOf("primary", "backup"), rating = null),
            MonitorMediaProjectionFacts(c, format = "MP4", resolution = "4K", photoSize = "large",
                dateWindows = setOf("today"), storageMembership = setOf("backup"), rating = 4),
            MonitorMediaProjectionFacts(d, format = "MOV", resolution = "HD", photoSize = "large",
                dateWindows = setOf("today"), storageMembership = setOf("backup")),
        ))
        assertEquals(listOf(a, b, c, d), MonitorMediaProjection.project(listOf(a, b, c, d), MonitorMediaProjectionRequest(), policy).displayIDs)
        val filtered = MonitorMediaProjection.project(listOf(a, b, c, d), MonitorMediaProjectionRequest(
            formats = setOf("MOV", "MP4"), resolutions = setOf("4K"), photoSizes = setOf("large"),
            dateWindow = "today", storage = "backup"), policy)
        assertEquals(listOf(b, c), filtered.displayIDs)
        assertNull(policy.rows[1].rating)
        assertEquals(emptyList(), MonitorMediaProjection.project(listOf(a, b), MonitorMediaProjectionRequest(requireLocal = true), policy).displayIDs)
    }

    @Test fun categoryPreparationPrecedesChipsAndLocalEligibility() {
        val offered = MonitorMediaProjectionOffered(formats = listOf("JPEG"), photoSizes = listOf("large", "small"))
        val policy = Policy(listOf(
            MonitorMediaProjectionFacts(a, format = "JPEG", photoSize = "large", localEligible = false),
            MonitorMediaProjectionFacts(b, format = "JPEG", photoSize = "small", localEligible = true),
        ), offered = offered)
        val result = MonitorMediaProjection.project(listOf(a, b), MonitorMediaProjectionRequest(
            category = MonitorMediaProjectionCategory.PHOTOS, photoSizes = setOf("small"), requireLocal = true), policy)
        assertEquals(listOf(a, b), result.categoryIDs)
        assertEquals(listOf(b), result.displayIDs)
        assertEquals(offered, result.offered)
    }

    @Test fun companionIsHiddenOnlyWhenPreferredSurvivesEveryFilter() {
        val policy = Policy(listOf(
            MonitorMediaProjectionFacts(a, format = "JPEG", pair = MonitorMediaProjectionPair("pair", MonitorMediaProjectionPairRole.PREFERRED), localEligible = false),
            MonitorMediaProjectionFacts(b, format = "RAW", pair = MonitorMediaProjectionPair("pair", MonitorMediaProjectionPairRole.COMPANION), localEligible = true),
            MonitorMediaProjectionFacts(c, format = "RAW", pair = MonitorMediaProjectionPair("other", MonitorMediaProjectionPairRole.COMPANION), localEligible = true),
        ))
        assertEquals(listOf(a, c), MonitorMediaProjection.project(listOf(a, b, c), MonitorMediaProjectionRequest(), policy).gridIDs)
        assertEquals(listOf(b, c), MonitorMediaProjection.project(listOf(a, b, c), MonitorMediaProjectionRequest(requireLocal = true), policy).gridIDs)
        assertEquals(listOf(b, c), MonitorMediaProjection.project(listOf(a, b, c), MonitorMediaProjectionRequest(formats = setOf("RAW")), policy).gridIDs)
    }

    @Test fun groupingStageUsesExactSurvivorOrderAndSelectionBasisIsExplicit() {
        val rows = listOf(MonitorMediaProjectionFacts(a), MonitorMediaProjectionFacts(b), MonitorMediaProjectionFacts(c))
        val before = Policy(rows, order = listOf(c, b, a), groupAll = true)
        val after = Policy(rows, order = listOf(c, b, a), stage = MonitorMediaProjectionGroupStage.AFTER_SORT, groupAll = true)
        val left = MonitorMediaProjection.project(listOf(a, b, c), MonitorMediaProjectionRequest(), before)
        val right = MonitorMediaProjection.project(listOf(a, b, c), MonitorMediaProjectionRequest(selectionScope = MonitorMediaProjectionSelectionScope.ALL_SURVIVORS), after)
        assertEquals(listOf(a), left.gridIDs)
        assertEquals(listOf(a), left.selected(setOf(a, b, c)))
        assertEquals(listOf(MonitorMediaProjectionGroup(a, listOf(a, b, c))), left.groups)
        assertEquals(listOf(c), right.gridIDs)
        assertEquals(listOf(c, b, a), right.selected(setOf(a, b, c)))
        assertEquals(listOf(MonitorMediaProjectionGroup(c, listOf(c, b, a))), right.groups)
        assertNull(right.group(b))
    }

    @Test fun expansionPreservesSuppliedPayloadAuthorityAndAvailableMemberFallback() {
        val policy = Policy(listOf(MonitorMediaProjectionFacts(a), MonitorMediaProjectionFacts(b), MonitorMediaProjectionFacts(c)), groupAll = true)
        val result = MonitorMediaProjection.project(listOf(a, b, c), MonitorMediaProjectionRequest(), policy)
        assertEquals(listOf(MonitorMediaProjectionExpansionEntry.Supplied(b), MonitorMediaProjectionExpansionEntry.Member(a),
            MonitorMediaProjectionExpansionEntry.Member(c), MonitorMediaProjectionExpansionEntry.Supplied(d)), result.expansion(listOf(b, a, b, d)))
        assertEquals(listOf(a, b, c, d), result.expanded(listOf(a, d, a)))
        assertEquals(listOf(MonitorMediaProjectionExpansionEntry.Member(b), MonitorMediaProjectionExpansionEntry.Supplied(d)),
            result.expansion(listOf(a, d), availableMemberIDs = setOf(b)))
        assertEquals(listOf(MonitorMediaProjectionExpansionEntry.Supplied(a), MonitorMediaProjectionExpansionEntry.Supplied(d)),
            result.expansion(listOf(a, d), availableMemberIDs = emptySet()))
    }

    @Test fun foreignFactsAndGroupsCannotIntroduceOrHideUnadmittedRows() {
        val foreign = MediaAssetID("foreign")
        val policy = Policy(listOf(MonitorMediaProjectionFacts(a), MonitorMediaProjectionFacts(b), MonitorMediaProjectionFacts(c), MonitorMediaProjectionFacts(foreign)), fixedGroups = listOf(
            MonitorMediaProjectionGroup(a, listOf(a, foreign)),
            MonitorMediaProjectionGroup(a, listOf(a, b, b)),
            MonitorMediaProjectionGroup(b, listOf(b, c)),
            MonitorMediaProjectionGroup(foreign, listOf(c)),
        ))
        val result = MonitorMediaProjection.project(listOf(a, b, c, a), MonitorMediaProjectionRequest(), policy)
        assertEquals(listOf(a, b, c), result.categoryIDs)
        assertEquals(listOf(a, c), result.gridIDs)
        assertEquals(listOf(MonitorMediaProjectionGroup(a, listOf(a, b))), result.groups)
    }

    @Test fun sortingPreservesDuplicateSuppliedIDsAndStableSourceTies() {
        val policy = Policy(emptyList(), order = listOf(b, a))
        assertEquals(listOf(b, a, a, c, d), MonitorMediaProjection.sorted(listOf(a, b, a, c, d), MonitorMediaProjectionSort.NAME, policy))
        val tied = Policy(emptyList())
        assertEquals(listOf(c, a, c, b), MonitorMediaProjection.sorted(listOf(c, a, c, b), MonitorMediaProjectionSort.RATING, tied))
    }

    private class Policy(
        val rows: List<MonitorMediaProjectionFacts>,
        val offered: MonitorMediaProjectionOffered = MonitorMediaProjectionOffered(),
        val order: List<MediaAssetID> = emptyList(),
        val stage: MonitorMediaProjectionGroupStage = MonitorMediaProjectionGroupStage.BEFORE_SORT,
        val groupAll: Boolean = false,
        val fixedGroups: List<MonitorMediaProjectionGroup> = emptyList(),
    ) : MonitorMediaProjectionPolicy {
        override val groupStage get() = stage
        override fun prepareCategory(ids: List<MediaAssetID>, category: MonitorMediaProjectionCategory) = MonitorMediaProjectionCategoryFacts(rows, offered)
        override fun compare(lhs: MediaAssetID, rhs: MediaAssetID, sort: MonitorMediaProjectionSort): Int {
            val left = order.indexOf(lhs).takeIf { it >= 0 } ?: order.size
            val right = order.indexOf(rhs).takeIf { it >= 0 } ?: order.size
            return left.compareTo(right)
        }
        override fun groups(ids: List<MediaAssetID>): List<MonitorMediaProjectionGroup> =
            if (groupAll && ids.isNotEmpty()) listOf(MonitorMediaProjectionGroup(ids.first(), ids)) else fixedGroups
    }
}
