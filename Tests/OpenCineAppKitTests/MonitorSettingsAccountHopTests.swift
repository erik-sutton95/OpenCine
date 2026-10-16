import Foundation
@testable import OpenCineAppKit
import Testing

/// A SIMULATED camera network the app's one internet hop leaves and rejoins.
@MainActor private final class AccountHopFacts {
    final class Session {}
    struct Route { let session: Session; let ssid: String }
    var session = Session()
    var onCameraNetwork = true
    var online = true
    var calls: [String] = []
    var connectError: (any Error)?

    @available(macOS 14, *)
    func hop() -> MonitorInternetHop<Route> {
        .init(
            port: .init(
                onCameraNetwork: { self.onCameraNetwork },
                leave: { route, _ in
                    self.calls.append("leave \(route.ssid)")
                    self.onCameraNetwork = false
                    return route
                },
                admitsReturn: { $0.session === self.session },
                rejoin: { route, _ in
                    self.calls.append("rejoin \(route.ssid)")
                    self.onCameraNetwork = true
                },
                online: { self.online }),
            sleep: { _ in await Task.yield() })
    }

    @available(macOS 14, *)
    func actions(_ hop: MonitorInternetHop<Route>, identity: String = "account") -> MonitorSettingsAccountActions {
        .overInternetHop(
            identity: identity, isCurrent: { true },
            connect: {
                self.calls.append(self.onCameraNetwork ? "connect on camera" : "connect off camera")
                if let error = self.connectError { throw error }
            },
            disconnect: { self.calls.append("disconnect") }, hop: hop,
            route: { Route(session: self.session, ssid: "CAM") }, internetFailure: "SIMULATED no internet")
    }
}

private struct AccountHopFailure: LocalizedError { let errorDescription: String? }

/// A2-23: the settings account sign-in on the camera's Wi-Fi asks first, leaves through the app's
/// one internet hop, signs in off the camera network, comes back, and shows what went wrong.
@MainActor @Suite struct MonitorSettingsAccountHopTests {
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<2000 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }

    @Test func signInOnTheCameraNetworkAsksLeavesSignsInAndComesBack() async {
        guard #available(macOS 14, *) else { return }
        let facts = AccountHopFacts(), model = MonitorSettingsAccountModel()
        let actions = facts.actions(facts.hop())
        #expect(actions.requiresInternetConsent == true)
        model.bind(actions)
        model.requestSignIn()
        #expect(model.confirmationPresented)
        #expect(facts.calls.isEmpty, "Nothing leaves the camera before the operator agrees")
        model.confirmSignIn()
        #expect(await settled { !model.busy && facts.calls.count == 3 })
        #expect(facts.calls == ["leave CAM", "connect off camera", "rejoin CAM"])
        #expect(model.failure == nil && !model.failed)
    }

    @Test func noInternetAfterLeavingShowsTheFailureAndStillComesBack() async {
        guard #available(macOS 14, *) else { return }
        let facts = AccountHopFacts(), model = MonitorSettingsAccountModel()
        facts.online = false
        model.bind(facts.actions(facts.hop()))
        model.requestSignIn(); model.confirmSignIn()
        #expect(await settled { !model.busy && facts.calls.count == 2 })
        #expect(facts.calls == ["leave CAM", "rejoin CAM"])
        #expect(model.failed && model.failure == "SIMULATED no internet")
    }

    @Test func aSignInErrorIsShownNotDropped() async {
        guard #available(macOS 14, *) else { return }
        let facts = AccountHopFacts(), model = MonitorSettingsAccountModel()
        facts.connectError = AccountHopFailure(errorDescription: "SIMULATED sign-in failed")
        model.bind(facts.actions(facts.hop()))
        model.requestSignIn(); model.confirmSignIn()
        #expect(await settled { !model.busy && facts.calls.count == 3 })
        #expect(facts.calls == ["leave CAM", "connect off camera", "rejoin CAM"])
        #expect(model.failure == "SIMULATED sign-in failed")
    }

    @Test func offTheCameraNetworkSignInNeedsNoConsentAndNoHop() async {
        guard #available(macOS 14, *) else { return }
        let facts = AccountHopFacts(), model = MonitorSettingsAccountModel()
        facts.onCameraNetwork = false
        let actions = facts.actions(facts.hop())
        #expect(actions.requiresInternetConsent == false)
        model.bind(actions)
        model.requestSignIn()
        #expect(!model.confirmationPresented)
        #expect(await settled { !model.busy && !facts.calls.isEmpty })
        #expect(facts.calls == ["connect off camera"])
    }

    @Test func aRunningHopRefusesASecondSettingsLease() {
        guard #available(macOS 14, *) else { return }
        let facts = AccountHopFacts()
        let hop = facts.hop()
        let route = AccountHopFacts.Route(session: facts.session, ssid: "CAM")
        let first = hop.settingsLease(route, admission: { true })
        #expect(first != nil)
        #expect(hop.settingsLease(route, admission: { true }) == nil)
        #expect(hop.settingsLease(route, admission: { false }) == nil)
        #expect(first?.isCurrent() == true)
    }

    @Test func aReplacedSourceNeverSignsInThroughTheOldHop() async {
        guard #available(macOS 14, *) else { return }
        let facts = AccountHopFacts(), model = MonitorSettingsAccountModel()
        facts.online = false
        let hop = facts.hop()
        model.bind(facts.actions(hop))
        model.requestSignIn(); model.confirmSignIn()
        #expect(await settled { facts.calls == ["leave CAM"] })
        facts.online = true
        model.bind(facts.actions(hop, identity: "successor"))
        #expect(await settled { facts.calls.count == 2 })
        for _ in 0..<50 { await Task.yield() }
        #expect(facts.calls == ["leave CAM", "rejoin CAM"], "The old sign-in ends and only comes back")
        #expect(!model.busy && model.failure == nil)
    }
}
