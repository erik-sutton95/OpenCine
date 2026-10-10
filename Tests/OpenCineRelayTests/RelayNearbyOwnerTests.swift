import Foundation
import OpenCineRelay
import Testing

@Suite struct RelayNearbyOwnerTests {
    private struct Presence: Sendable, Equatable {
        let name: String
        let watchable: Bool
        let port: Int?
        let bytes: Data
        init(_ name: String, _ watchable: Bool = true, _ port: Int? = 5000) {
            self.name = name
            self.watchable = watchable
            self.port = port
            bytes = Data(name.utf8)
        }
    }
    private typealias Row = RelayDiscoveryRow<String>
    private typealias Owner = RelayNearbyOwner<Row, Presence>
    private func owner(
        hidden: RelayNearbyLedgerPolicy.HiddenIdentity = .sourceAddress,
        duplicate: RelayNearbyLedgerPolicy.DuplicateIdentity = .allListings,
        removes: Bool = true,
        confirmation: RelayNearbyLedgerPolicy.Confirmation = .watchableAnswers
    ) -> Owner {
        Owner(
            policy: .init(
                hiddenIdentity: hidden, duplicateIdentity: duplicate,
                removesPresenceOnListingRemoval: removes, confirmation: confirmation),
            listingFacts: { .init(name: $0.name, isWatchable: $0.isWatchable) },
            presenceFacts: { .init(name: $0.name, isWatchable: $0.watchable, relayPort: $0.port) },
            presenceListing: { host, port, presence in
                guard port > 0 else { return nil }
                return Row(
                    id: "presence:\(host)", name: presence.name,
                    endpoint: "\(host):\(port)")
            })
    }

    @Test func authoritativeSweepRetainsShieldButAddsOnlyJoinableEndpoint() {
        var ledger = owner()
        let shield = Row(id: "shield", name: "Held in-use", endpoint: "shield", isWatchable: false)
        let live = Row(id: "live", name: "Live", endpoint: "bonjour")
        ledger.acceptListingEvent([shield, live])
        let hits = [
            "h1": Presence("Held", false, nil), "h2": Presence("Live", true, 5021),
            "h3": Presence("Only direct", true, 5030), "h4": Presence("Self"),
            "h5": Presence("Portless", true, nil), "h6": Presence("Invalid", true, 0),
        ]
        ledger.applySweep(hits, selfName: "Self", now: 0)
        #expect(ledger.presences == hits, "raw deployed payloads are retained exactly")
        #expect(ledger.listings.count == 2 && ledger.listings[0].isWatchable == false)
        #expect(
            ledger.watchableListings(selfName: "Self").map(\.endpoint) == ["bonjour", "h3:5030"])
        ledger.applySweep(["h1": hits["h1"]!], selfName: "Self", now: 1)
        #expect(ledger.watchableListings(selfName: "Self").isEmpty)
        #expect(
            ledger.refutedNames.contains("Live"),
            "an in-use device does not confirm its old broadcast")
        ledger.applySweep(["h2": hits["h2"]!], selfName: "Self", now: 2)
        #expect(ledger.watchableListings(selfName: "Self").map(\.endpoint) == ["bonjour"])
        #expect(ledger.presences.count == 1)
    }

    @Test func filteringIsContinuousTenSecondsAndNeverCountsCameraInUseShield() {
        var ledger = owner()
        let hits = ["h": Presence("Live")]
        ledger.applySweep(hits, selfName: "Self", now: 1)
        ledger.applySweep(hits, selfName: "Self", now: 10.999)
        #expect(!ledger.networkFiltersDiscovery)
        ledger.applySweep(hits, selfName: "Self", now: 11)
        #expect(ledger.networkFiltersDiscovery)
        ledger.acceptListingEvent([Row(id: "live", name: "Live", endpoint: "visible")])
        ledger.applySweep(hits, selfName: "Self", now: 11.001)
        #expect(!ledger.networkFiltersDiscovery)
        ledger.acceptListingEvent([])
        ledger.applySweep(hits, selfName: "Self", now: 12)
        #expect(!ledger.networkFiltersDiscovery)
        ledger.applySweep([:], selfName: "Self", now: 30)
        #expect(!ledger.networkFiltersDiscovery && ledger.presences.isEmpty)
        ledger.applySweep(["h": Presence("Held", false)], selfName: "Self", now: 31)
        ledger.applySweep(["h": Presence("Held", false)], selfName: "Self", now: 99)
        #expect(!ledger.networkFiltersDiscovery)
    }

    @Test func actualListingRemovalPrunesKnownPresenceButKeepsFilteredOnlySource() {
        var ledger = owner()
        ledger.acceptListingEvent([Row(id: "known", name: "Known", endpoint: "visible")])
        ledger.applySweep(
            ["h1": Presence("Known"), "h2": Presence("Hidden")], selfName: "Self", now: 0)
        ledger.acceptListingEvent([])
        #expect(ledger.presences.keys.sorted() == ["h2"])
        #expect(ledger.watchableListings(selfName: "Self").map(\.name) == ["Hidden"])
        ledger.replaceListings([Row(id: "known", name: "Known", endpoint: "visible")])
        ledger.applySweep(
            ["h1": Presence("Known"), "h2": Presence("Hidden")], selfName: "Self", now: 1)
        ledger.replaceListings([])
        #expect(ledger.presences.count == 2, "retirement is not an invented native goodbye")
    }

    @Test func continuityAndDuplicateRecipesPreserveDeployedDifferences() {
        var address = owner()
        var name = owner(hidden: .name, duplicate: .unrefutedListings, removes: false)
        for instant in [0.0, 9.0] {
            address.applySweep(["a": Presence("Same")], selfName: "Self", now: instant)
            name.applySweep(["a": Presence("Same")], selfName: "Self", now: instant)
        }
        address.applySweep(["b": Presence("Same")], selfName: "Self", now: 10)
        name.applySweep(["b": Presence("Same")], selfName: "Self", now: 10)
        #expect(!address.networkFiltersDiscovery && name.networkFiltersDiscovery)
        let live = Row(id: "live", name: "Same", endpoint: "old listing")
        address.replaceListings([live])
        name.replaceListings([live])
        // The prior authoritative sweep refuted this newly composed row on neither recipe.
        address.applySweep([:], selfName: "Self", now: 11)
        name.applySweep([:], selfName: "Self", now: 11)
        #expect(address.watchableListings(selfName: "Self").isEmpty)
        #expect(name.watchableListings(selfName: "Self").isEmpty)
        address.applySweep(["b": Presence("Same")], selfName: "Self", now: 12)
        name.applySweep(["b": Presence("Same")], selfName: "Self", now: 12)
        #expect(address.watchableListings(selfName: "Self").map(\.endpoint) == ["old listing"])
        #expect(name.watchableListings(selfName: "Self").map(\.endpoint) == ["old listing"])
    }

    @Test func oldSweepResultAndFinallyCannotPublishOrRetireSuccessor() {
        var ledger = owner()
        let old = ledger.beginSweep()
        let next = ledger.beginSweep()
        let oldPublished = ledger.applySweep(
            ["old": Presence("Same")], selfName: "Self", now: 0, source: old)
        #expect(!oldPublished && ledger.presences.isEmpty)
        ledger.retireSweep(old)
        let currentPublished = ledger.applySweep(
            ["next": Presence("Same")], selfName: "Self", now: 1, source: next)
        #expect(currentPublished && ledger.presences.keys.sorted() == ["next"])
        ledger.retireSweep(next)
        let latePublished = ledger.applySweep([:], selfName: "Self", now: 99, source: next)
        #expect(!latePublished && ledger.presences.keys.sorted() == ["next"])
        let reentry = ledger.beginSweep()
        let expired = ledger.applySweep([:], selfName: "Self", now: 100, source: reentry)
        #expect(expired && ledger.presences.isEmpty && !ledger.networkFiltersDiscovery)
    }

    @Test func limitedSweepClockEvaluationDoesNotInventNewRefutations() {
        var ledger = owner()
        let source = ledger.beginSweep()
        ledger.replaceListings([Row(id: "new", name: "New", endpoint: "new native")])
        let first = ledger.evaluateFiltering(selfName: "Self", now: 0, source: source)
        #expect(first && ledger.refutedNames.isEmpty)
        let report = ledger.applySweep(
            ["h": Presence("Hidden")], selfName: "Self", now: 1, source: source)
        #expect(report && !ledger.networkFiltersDiscovery && ledger.refutedNames.contains("New"))
        let evaluated = ledger.evaluateFiltering(selfName: "Self", now: 11, source: source)
        #expect(evaluated && ledger.networkFiltersDiscovery)
        ledger.replaceListings([Row(id: "hidden", name: "Hidden", endpoint: "now visible")])
        let clear = ledger.evaluateFiltering(selfName: "Self", now: 12, source: source)
        #expect(clear && !ledger.networkFiltersDiscovery && ledger.refutedNames == ["New"])
        ledger.retireSweep(source)
        let late = ledger.evaluateFiltering(selfName: "Self", now: 99, source: source)
        #expect(!late && !ledger.networkFiltersDiscovery)
    }

    @Test func answerConfirmationRecipeKeepsOriginalShieldRefutationDifference() {
        var watchable = owner()
        var anyAnswer = owner(confirmation: .allAnswers)
        let listing = Row(id: "old", name: "Same", endpoint: "old broadcast")
        let shield = ["h": Presence("Same", false, nil)]
        watchable.replaceListings([listing])
        anyAnswer.replaceListings([listing])
        watchable.applySweep(shield, selfName: "Self", now: 0)
        anyAnswer.applySweep(shield, selfName: "Self", now: 0)
        #expect(watchable.watchableListings(selfName: "Self").isEmpty)
        #expect(anyAnswer.watchableListings(selfName: "Self").map(\.endpoint) == ["old broadcast"])
        #expect(!watchable.networkFiltersDiscovery && !anyAnswer.networkFiltersDiscovery)
    }
}
