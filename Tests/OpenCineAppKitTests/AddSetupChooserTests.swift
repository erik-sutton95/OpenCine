import OpenCineAppKit
import OpenCineCore
import Testing

/// SIMULATED capabilities; selection dispatch never talks to a camera.
@MainActor
@Suite struct AddSetupChooserTests {
    @Test func onlyEnabledAdvertisedCapabilitiesCanBeSelected() {
        let chooser = AddSetupChooser(
            title: "Add a setup", detail: "Choose a supported connection.",
            options: [
                AddSetupOption(
                    id: "wifi", kind: .infrastructureNetwork, title: "Wi-Fi",
                    detail: "Same network", actionTitle: "Find"),
                AddSetupOption(
                    id: "usb", kind: .usb, title: "Cable", detail: "Unavailable",
                    actionTitle: "Connect", enabled: false),
            ])
        var selected: [RouteKind] = []
        #expect(!chooser.select("missing", onSelect: { selected.append($0.kind) }))
        #expect(!chooser.select("usb", onSelect: { selected.append($0.kind) }))
        #expect(selected.isEmpty)
        #expect(chooser.select("wifi", onSelect: { selected.append($0.kind) }))
        #expect(selected == [.infrastructureNetwork])
    }
}
