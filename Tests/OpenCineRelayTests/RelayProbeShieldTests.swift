import OpenCineRelay
import Testing

/// SIMULATED supplied aliases and caller time. No discovery pass, socket or wall clock.
@Suite("Relay probe shield preserves its supplied host recipe")
struct RelayProbeShieldTests {
    private func owner(fallback: Bool = true) -> RelayProbeShield {
        RelayProbeShield(policy: .init(linger: 180, shieldsSavedHostsForUnnamedBroadcast: fallback))
    }

    @Test func knownBroadcastRetainsOnlySuppliedAliases() {
        var shield = owner()
        let aliases: Set<String> = ["camera.local", "192.0.2.10"]
        let held = shield.update(
            broadcastHostAliases: [aliases], presenceHostAliases: [],
            savedHostAliases: ["192.0.2.99"], now: 0)
        #expect(held == aliases)
    }

    @Test func missingAndEmptyBroadcastAttributionUseSuppliedFallback() {
        let saved: Set<String> = ["camera.local", "192.0.2.10"]
        var conservative = owner()
        var namedOnly = owner(fallback: false)
        let held = conservative.update(
            broadcastHostAliases: [nil, []], presenceHostAliases: [], savedHostAliases: saved,
            now: 0)
        let other = namedOnly.update(
            broadcastHostAliases: [nil, []], presenceHostAliases: [], savedHostAliases: saved,
            now: 0)
        #expect(held == saved)
        #expect(other.isEmpty)
    }

    @Test func unicastPresenceDoesNotInventAllSavedFallback() {
        var shield = owner()
        let empty = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: ["saved"], now: 0)
        #expect(empty.isEmpty)
        let aliases: Set<String> = ["served.local", "192.0.2.20"]
        let held = shield.update(
            broadcastHostAliases: [], presenceHostAliases: aliases, savedHostAliases: ["saved"],
            now: 1)
        #expect(held == aliases)
    }

    @Test func blinkReentryRenewsExactAliasAndKeepsOtherSourceIndependent() {
        var shield = owner()
        let a: Set<String> = ["a.local", "192.0.2.10"]
        shield.update(
            broadcastHostAliases: [a], presenceHostAliases: [], savedHostAliases: [], now: 0)
        let blink = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 80)
        #expect(blink == a)
        let both = shield.update(
            broadcastHostAliases: [["b"]], presenceHostAliases: [], savedHostAliases: [], now: 100)
        #expect(both == a.union(["b"]))
        let aExpired = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 180)
        #expect(aExpired == ["b"])
        let reentered = shield.update(
            broadcastHostAliases: [a], presenceHostAliases: [], savedHostAliases: [], now: 181)
        #expect(reentered == a.union(["b"]))
        let bExpired = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 280)
        #expect(bExpired == a)
    }

    @Test func expiryIsStrictAtLingerBoundary() {
        var shield = owner()
        shield.update(
            broadcastHostAliases: [["a"]], presenceHostAliases: [], savedHostAliases: [], now: 0)
        let before = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 179.999)
        let exact = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 180)
        #expect(before == ["a"])
        #expect(exact.isEmpty)
    }

    @Test func callerClockRollbackRetainsPastObservation() {
        var shield = owner()
        shield.update(
            broadcastHostAliases: [["a"]], presenceHostAliases: [], savedHostAliases: [], now: 100)
        let rollback = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 90)
        let before = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 279.999)
        let exact = shield.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 280)
        #expect(rollback == ["a"])
        #expect(before == ["a"])
        #expect(exact.isEmpty)
    }

    @Test func instancesAndReturnedHostValuesDoNotShareState() {
        var first = owner()
        var second = owner()
        var supplied: Set<String> = ["a"]
        let retained = first.update(
            broadcastHostAliases: [supplied], presenceHostAliases: [], savedHostAliases: [], now: 0)
        supplied.insert("unpublished")
        #expect(first.hosts == ["a"])
        let independent = second.update(
            broadcastHostAliases: [], presenceHostAliases: [], savedHostAliases: [], now: 0)
        #expect(independent.isEmpty)
        let next = first.update(
            broadcastHostAliases: [["b"]], presenceHostAliases: [], savedHostAliases: [], now: 10)
        #expect(next == ["a", "b"])
        #expect(retained == ["a"])
    }
}
