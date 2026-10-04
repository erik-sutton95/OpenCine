import MonitorPresentation
import Testing

struct MonitorMediaDeliveryProjectLabelTests {
    @Test func listedIDWinsOverSuppliedStaleLabel() {
        let service = MonitorMediaDeliveryValue.Service.projects(
            heading: "PROJECT", help: "", signInNotice: nil, loading: false, error: nil,
            choices: [.init(id: "SIMULATED/1", label: "Listed project")],
            selectedID: "SIMULATED/1", selectedLabel: "Stale name"
        )
        #expect(service.selectedProjectLabel == "Listed project")
    }

    @Test func knownDestinationOutsideOfferedChoicesDoesNotInventAChoice() {
        let service = MonitorMediaDeliveryValue.Service.projects(
            heading: "PROJECT", help: "", signInNotice: nil, loading: false, error: nil,
            choices: [.init(id: "SIMULATED/1", label: "Offered project")],
            selectedID: "SIMULATED/2", allowsCreation: false, selectedLabel: "Known destination"
        )
        #expect(service.selectedProjectLabel == "Known destination")
        guard case .projects(_, _, _, _, _, let choices, _, let allowsCreation, _) = service else {
            Issue.record("Expected supplied project facts")
            return
        }
        #expect(choices?.map(\.id) == ["SIMULATED/1"])
        #expect(!allowsCreation)
    }

    @Test func defaultAndUnavailableLabelsRemainAbsent() {
        let service = MonitorMediaDeliveryValue.Service.projects(
            heading: "PROJECT", help: "", signInNotice: nil, loading: false, error: nil,
            choices: nil, selectedID: nil
        )
        #expect(service.selectedProjectLabel == nil)
        #expect(
            MonitorMediaDeliveryValue.Service.internetGate(
                heading: "NETWORK", message: "", busy: false
            ).selectedProjectLabel == nil)
    }
}
