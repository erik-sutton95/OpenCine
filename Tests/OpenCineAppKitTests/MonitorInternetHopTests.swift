import Foundation
import OpenCineAppKit
import Testing

/// A SIMULATED camera session the hop leaves from.
@MainActor private final class HopSession {}

@MainActor private final class HopFacts {
    var session = HopSession()
    var onCameraNetwork = true
    var online = false
    var calls: [String] = []
    var leaveGate: [CheckedContinuation<Void, Never>] = []
    var holdsLeave = false
    var leaves = true

    struct Route { let session: HopSession; let ssid: String }

    func hop() -> MonitorInternetHop<Route> {
        .init(
            port: .init(
                onCameraNetwork: { self.onCameraNetwork },
                leave: { route, _ in
                    if self.holdsLeave { await withCheckedContinuation { self.leaveGate.append($0) } }
                    self.calls.append("leave \(route.ssid)")
                    guard self.leaves else { return nil }
                    self.onCameraNetwork = false
                    return route
                },
                admitsReturn: { $0.session === self.session },
                rejoin: { route, _ in self.calls.append("rejoin \(route.ssid)") },
                online: { self.online }),
            sleep: { _ in await Task.yield() })
    }

    func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { await Task.yield() }
    }
}

@MainActor struct MonitorInternetHopTests {
    @Test func aSecondBeginIsRefusedWhileAHopRuns() async {
        let facts = HopFacts()
        let hop = facts.hop()
        let first = hop.begin(.init(session: facts.session, ssid: "CAM"))
        #expect(first != nil)
        #expect(hop.begin(.init(session: facts.session, ssid: "OTHER")) == nil)
        await facts.settle { facts.calls == ["leave CAM"] }
        #expect(facts.calls == ["leave CAM"])
        #expect(hop.owns(first!))
    }

    @Test func aStaleTokenCannotEndTheHop() async {
        let facts = HopFacts()
        let hop = facts.hop()
        let popup = hop.begin(.init(session: facts.session, ssid: "CAM"))!
        await facts.settle { facts.calls == ["leave CAM"] }
        let run = hop.transfer(popup)!
        #expect(hop.end(popup) == nil)
        #expect(hop.isActive && hop.owns(run) && !hop.owns(popup))
        await hop.end(run)?.value
        #expect(!hop.isActive && hop.ended(run) && !hop.ended(popup))
        #expect(facts.calls == ["leave CAM", "rejoin CAM"])
    }

    @Test func theReturnIsConsumedOnceAndNeverAfterASessionSwap() async {
        let facts = HopFacts()
        let hop = facts.hop()
        let token = hop.begin(.init(session: facts.session, ssid: "CAM"))!
        await facts.settle { facts.calls == ["leave CAM"] }
        let rejoin = hop.end(token)
        #expect(hop.end(token) == nil)
        await rejoin?.value
        #expect(facts.calls == ["leave CAM", "rejoin CAM"])

        let swapped = hop.begin(.init(session: facts.session, ssid: "CAM2"))!
        await facts.settle { facts.calls.count == 3 }
        facts.session = HopSession()
        await hop.end(swapped)?.value
        #expect(facts.calls == ["leave CAM", "rejoin CAM", "leave CAM2"], "A replaced session is never rejoined")
    }

    @Test func aHopEndedWhileLeavingStillOwesItsReturn() async {
        let facts = HopFacts()
        facts.holdsLeave = true
        let hop = facts.hop()
        let token = hop.begin(.init(session: facts.session, ssid: "CAM"))!
        await facts.settle { facts.leaveGate.count == 1 }
        #expect(hop.end(token) == nil, "Nothing has left yet")
        facts.leaveGate.removeFirst().resume()
        await facts.settle { facts.calls.count == 2 }
        #expect(facts.calls == ["leave CAM", "rejoin CAM"])
    }

    @Test func aFailedLeaveEndsTheHopWithNothingToRejoin() async {
        let facts = HopFacts()
        facts.leaves = false
        let hop = facts.hop()
        let token = hop.begin(.init(session: facts.session, ssid: "CAM"))!
        await facts.settle { !hop.isActive }
        #expect(!hop.isActive && hop.ended(token))
        #expect(facts.calls == ["leave CAM"])
    }

    @Test func waitingNeedsAnInternetRouteOffTheCameraNetwork() async {
        let facts = HopFacts()
        let hop = facts.hop()
        let token = hop.begin(.init(session: facts.session, ssid: "CAM"))!
        #expect(await hop.waitForInternet(token, timeout: .seconds(2)) == false, "Off the camera without a route")
        facts.online = true
        #expect(await hop.waitForInternet(token, timeout: .seconds(2)))
        let run = hop.transfer(token)!
        #expect(await hop.waitForInternet(token, timeout: .seconds(2)) == false, "A retired token never waits")
        _ = hop.end(run)
    }

    @Test func theDeliveryLeaseIsRefusedWhileAnotherHopRuns() async {
        let facts = HopFacts()
        let hop = facts.hop()
        let service = hop.deliveryService(route: { .init(session: facts.session, ssid: "CAM") })
        #expect(service.needsHop())
        let first = service.begin()
        #expect(first != nil && service.owns(first!))
        #expect(service.begin() == nil)
        await facts.settle { facts.calls == ["leave CAM"] }
        await service.restoreEntered(first!)
        #expect(!hop.isActive)
        #expect(facts.calls == ["leave CAM", "rejoin CAM"])
    }

    @Test func anEndedHopPublishesOnceAndASuccessorCannotReviveIt() async {
        let facts = HopFacts()
        let hop = facts.hop()
        let old = hop.begin(.init(session: facts.session, ssid: "CAM"))!
        #expect(!hop.ended(old))
        _ = hop.end(old)
        #expect(hop.ended(old) && hop.end(old) == nil && hop.ended(old))
        let successor = hop.begin(.init(session: facts.session, ssid: "CAM2"))!
        #expect(!hop.ended(old) && !hop.ended(successor))
        _ = hop.end(successor)
        #expect(hop.ended(successor) && !hop.ended(old))
    }

    @Test func anotherHopCannotBorrowATokenItNeverIssued() async {
        let facts = HopFacts()
        let hop = facts.hop()
        let other = facts.hop()
        let mine = hop.begin(.init(session: facts.session, ssid: "CAM"))!
        let theirs = other.begin(.init(session: facts.session, ssid: "CAM"))!
        #expect(hop.transfer(theirs) == nil && hop.end(theirs) == nil && !hop.owns(theirs))
        #expect(hop.owns(mine))
        _ = other.end(theirs)
        #expect(!hop.ended(theirs) && !other.ended(mine))
        _ = hop.end(mine)
    }
}
