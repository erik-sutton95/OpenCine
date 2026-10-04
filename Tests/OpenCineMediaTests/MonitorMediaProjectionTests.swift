import Foundation
import OpenCineMedia
import Testing

@Suite struct MonitorMediaProjectionTests {
    private let a = MediaAssetID("a")
    private let b = MediaAssetID("b")
    private let c = MediaAssetID("c")
    private let d = MediaAssetID("d")

    @Test func unknownFactsSurviveWithoutSelectionsAndSelectedGroupsRequireKnownMatches() {
        let policy = Policy(rows: [
            .init(id: a),
            .init(
                id: b, format: "MOV", resolution: "4K", photoSize: "large",
                dateWindows: ["today"], storageMembership: ["primary", "backup"], rating: nil),
            .init(
                id: c, format: "MP4", resolution: "4K", photoSize: "large",
                dateWindows: ["today"], storageMembership: ["backup"], rating: 4),
            .init(
                id: d, format: "MOV", resolution: "HD", photoSize: "large",
                dateWindows: ["today"], storageMembership: ["backup"]),
        ])
        #expect(
            MonitorMediaProjection.project([a, b, c, d], request: .init(), policy: policy)
                .displayIDs == [a, b, c, d])
        let filtered = MonitorMediaProjection.project(
            [a, b, c, d],
            request: .init(
                formats: ["MOV", "MP4"], resolutions: ["4K"], photoSizes: ["large"],
                dateWindow: "today", storage: "backup"), policy: policy)
        #expect(filtered.displayIDs == [b, c])
        #expect(policy.rows[1].rating == nil)
        #expect(
            MonitorMediaProjection.project(
                [a, b], request: .init(requireLocal: true), policy: policy
            ).displayIDs.isEmpty)
    }

    @Test func categoryPreparationPrecedesChipsAndLocalEligibility() {
        let offered = MonitorMediaProjectionOffered(
            formats: ["JPEG"], photoSizes: ["large", "small"])
        let policy = Policy(
            rows: [
                .init(id: a, format: "JPEG", photoSize: "large", localEligible: false),
                .init(id: b, format: "JPEG", photoSize: "small", localEligible: true),
            ], offered: offered)
        let result = MonitorMediaProjection.project(
            [a, b],
            request: .init(
                category: .photos, photoSizes: ["small"], requireLocal: true), policy: policy)
        #expect(result.categoryIDs == [a, b])
        #expect(result.displayIDs == [b])
        #expect(result.offered == offered)
    }

    @Test func companionIsHiddenOnlyWhenPreferredSurvivesEveryFilter() {
        let policy = Policy(rows: [
            .init(
                id: a, format: "JPEG", pair: .init(identity: "pair", role: .preferred),
                localEligible: false),
            .init(
                id: b, format: "RAW", pair: .init(identity: "pair", role: .companion),
                localEligible: true),
            .init(
                id: c, format: "RAW", pair: .init(identity: "other", role: .companion),
                localEligible: true),
        ])
        #expect(
            MonitorMediaProjection.project([a, b, c], request: .init(), policy: policy).gridIDs == [
                a, c,
            ])
        #expect(
            MonitorMediaProjection.project(
                [a, b, c], request: .init(requireLocal: true), policy: policy
            ).gridIDs == [b, c])
        #expect(
            MonitorMediaProjection.project(
                [a, b, c], request: .init(formats: ["RAW"]), policy: policy
            ).gridIDs == [b, c])
    }

    @Test func groupingStageUsesExactSurvivorOrderAndSelectionBasisIsExplicit() {
        let rows: [MonitorMediaProjectionFacts] = [.init(id: a), .init(id: b), .init(id: c)]
        let before = Policy(rows: rows, order: [c, b, a], groupAll: true)
        let after = Policy(rows: rows, order: [c, b, a], stage: .afterSort, groupAll: true)
        let left = MonitorMediaProjection.project([a, b, c], request: .init(), policy: before)
        let right = MonitorMediaProjection.project(
            [a, b, c], request: .init(selectionScope: .allSurvivors), policy: after)
        #expect(left.gridIDs == [a])
        #expect(left.selected([a, b, c]) == [a])
        #expect(left.groups == [.init(representative: a, members: [a, b, c])])
        #expect(right.gridIDs == [c])
        #expect(right.selected([a, b, c]) == [c, b, a])
        #expect(right.groups == [.init(representative: c, members: [c, b, a])])
        #expect(right.group(for: b) == nil)
    }

    @Test func expansionPreservesSuppliedPayloadAuthorityAndAvailableMemberFallback() {
        let policy = Policy(rows: [.init(id: a), .init(id: b), .init(id: c)], groupAll: true)
        let result = MonitorMediaProjection.project([a, b, c], request: .init(), policy: policy)
        #expect(
            result.expansion([b, a, b, d]) == [.supplied(b), .member(a), .member(c), .supplied(d)])
        #expect(result.expanded([a, d, a]) == [a, b, c, d])
        #expect(result.expansion([a, d], availableMemberIDs: [b]) == [.member(b), .supplied(d)])
        #expect(result.expansion([a, d], availableMemberIDs: []) == [.supplied(a), .supplied(d)])
    }

    @Test func foreignFactsAndGroupsCannotIntroduceOrHideUnadmittedRows() {
        let foreign = MediaAssetID("foreign")
        let policy = Policy(
            rows: [.init(id: a), .init(id: b), .init(id: c), .init(id: foreign)],
            fixedGroups: [
                .init(representative: a, members: [a, foreign]),
                .init(representative: a, members: [a, b, b]),
                .init(representative: b, members: [b, c]),
                .init(representative: foreign, members: [c]),
            ])
        let result = MonitorMediaProjection.project([a, b, c, a], request: .init(), policy: policy)
        #expect(result.categoryIDs == [a, b, c])
        #expect(result.gridIDs == [a, c])
        #expect(result.groups == [.init(representative: a, members: [a, b])])
    }

    @Test func sortingPreservesDuplicateSuppliedIDsAndStableSourceTies() {
        let policy = Policy(rows: [], order: [b, a])
        #expect(
            MonitorMediaProjection.sorted([a, b, a, c, d], sort: .name, policy: policy) == [
                b, a, a, c, d,
            ])
        let tied = Policy(rows: [])
        #expect(
            MonitorMediaProjection.sorted([c, a, c, b], sort: .rating, policy: tied) == [
                c, a, c, b,
            ])
    }

    private struct Policy: MonitorMediaProjectionPolicy {
        let rows: [MonitorMediaProjectionFacts]
        var offered = MonitorMediaProjectionOffered()
        var order: [MediaAssetID] = []
        var stage: MonitorMediaProjectionGroupStage = .beforeSort
        var groupAll = false
        var fixedGroups: [MonitorMediaProjectionGroup] = []
        var groupStage: MonitorMediaProjectionGroupStage { stage }
        func prepareCategory(_ ids: [MediaAssetID], category: MonitorMediaProjectionCategory)
            -> MonitorMediaProjectionCategoryFacts
        {
            .init(rows: rows, offered: offered)
        }
        func compare(_ lhs: MediaAssetID, _ rhs: MediaAssetID, sort: MonitorMediaProjectionSort)
            -> ComparisonResult
        {
            let left = order.firstIndex(of: lhs) ?? order.count
            let right = order.firstIndex(of: rhs) ?? order.count
            return left < right
                ? .orderedAscending : (left > right ? .orderedDescending : .orderedSame)
        }
        func groups(_ ids: [MediaAssetID]) -> [MonitorMediaProjectionGroup] {
            if groupAll, let first = ids.first {
                return [.init(representative: first, members: ids)]
            }
            return fixedGroups
        }
    }
}
