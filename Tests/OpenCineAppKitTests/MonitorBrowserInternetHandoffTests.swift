import Foundation
import OpenCineAppKit
import Testing

/// A SIMULATED camera network the Settings browser handoff leaves and rejoins.
@MainActor private final class BrowserHopFacts {
    final class Session {}
    struct Route { let session: Session; let ssid: String }
    var session = Session()
    var onCameraNetwork = true
    var online = true
    var opens = true
    var calls: [String] = []

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
    func actions(_ handoff: MonitorBrowserInternetHandoff<Route>, consent: Bool) -> MonitorSettingsSupportActions {
        .init(
            identity: "support", isCurrent: { true }, requiresInternetConsent: consent,
            makeReport: { throw MonitorSettingsReportUnavailable(supportEmail: "support@example.org") },
            prepareBrowser: { admission in
                await handoff.prepare(route: Route(session: self.session, ssid: "CAM"), admission: admission)
            },
            open: { url in
                self.calls.append((self.onCameraNetwork ? "open on camera " : "open off camera ") + url.host!)
                return self.opens
            }, internetFailure: "SIMULATED no internet")
    }
}

/// A2-22: Settings browser links on the camera's Wi-Fi ask, leave through the app's one internet
/// hop, open off the camera network and bring the camera back once the person returns.
@MainActor @Suite struct MonitorBrowserInternetHandoffTests {
    private let page = MonitorSettingsBrowserDestination(
        id: "settings.source", title: "Source Code", url: URL(string: "https://example.org/source")!,
        confirmationMessage: "SIMULATED leave?")

    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<2000 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }

    @Test func aPageOnTheCameraNetworkAsksLeavesOpensAndComesBackAfterTheBrowser() async {
        guard #available(macOS 14, *) else { return }
        let facts = BrowserHopFacts()
        let handoff = MonitorBrowserInternetHandoff(hop: facts.hop())
        let model = MonitorSettingsSupportModel()
        model.bind(facts.actions(handoff, consent: true))
        model.request(page)
        #expect(model.destination == page)
        #expect(facts.calls.isEmpty, "Nothing leaves the camera before the operator agrees")
        model.confirmBrowser()
        #expect(await settled { !model.preparingBrowser && facts.calls.count == 2 })
        #expect(facts.calls == ["leave CAM", "open off camera example.org"])
        #expect(handoff.isHolding && !model.browserFailed)
        #expect(handoff.becameActive() == nil, "An activation flicker while the page opens changes nothing")
        handoff.enteredBackground()
        await handoff.becameActive()?.value
        #expect(facts.calls == ["leave CAM", "open off camera example.org", "rejoin CAM"])
        #expect(!handoff.isHolding)
    }

    @Test func aPageTheBrowserDidNotOpenComesBackAtOnce() async {
        guard #available(macOS 14, *) else { return }
        let facts = BrowserHopFacts()
        facts.opens = false
        let handoff = MonitorBrowserInternetHandoff(hop: facts.hop())
        let model = MonitorSettingsSupportModel()
        model.bind(facts.actions(handoff, consent: true))
        model.request(page); model.confirmBrowser()
        #expect(await settled { !model.preparingBrowser && facts.calls.count == 3 })
        #expect(facts.calls == ["leave CAM", "open off camera example.org", "rejoin CAM"])
        #expect(!handoff.isHolding)
    }

    @Test func noInternetAfterLeavingShowsTheFailureAndComesBackWithoutOpening() async {
        guard #available(macOS 14, *) else { return }
        let facts = BrowserHopFacts()
        facts.online = false
        let handoff = MonitorBrowserInternetHandoff(hop: facts.hop())
        let model = MonitorSettingsSupportModel()
        model.bind(facts.actions(handoff, consent: true))
        model.request(page); model.confirmBrowser()
        #expect(await settled { !model.preparingBrowser && facts.calls.count == 2 })
        #expect(facts.calls == ["leave CAM", "rejoin CAM"])
        #expect(model.browserFailed && model.browserFailure == "SIMULATED no internet")
        #expect(!handoff.isHolding)
    }

    @Test func offTheCameraNetworkAPageOpensWithoutAskingOrHopping() async {
        guard #available(macOS 14, *) else { return }
        let facts = BrowserHopFacts()
        facts.onCameraNetwork = false
        let handoff = MonitorBrowserInternetHandoff(hop: facts.hop())
        let model = MonitorSettingsSupportModel()
        model.bind(facts.actions(handoff, consent: false))
        model.request(page)
        #expect(model.destination == nil)
        #expect(await settled { !model.preparingBrowser && !facts.calls.isEmpty })
        #expect(facts.calls == ["open off camera example.org"])
        #expect(!handoff.isHolding)
    }

    @Test func anUnsavedReportNamesTheSupportAddress() async {
        guard #available(macOS 14, *) else { return }
        let facts = BrowserHopFacts()
        let model = MonitorSettingsSupportModel()
        model.bind(facts.actions(MonitorBrowserInternetHandoff(hop: facts.hop()), consent: false))
        model.prepareReport()
        #expect(await settled { !model.preparingReport })
        #expect(model.reportFailed)
        #expect(model.reportFailure == "This phone couldn't save the report. Email support@example.org instead.")
    }
}
