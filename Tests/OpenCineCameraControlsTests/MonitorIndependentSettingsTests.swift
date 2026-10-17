import OpenCineCameraControls
import Testing

/// SIMULATED host targets exercise the neutral row contract without a camera policy.
@Suite struct MonitorIndependentSettingsTests {
    private enum Target: Equatable { case first, second }
    private typealias Row = IndependentSettingRow<String, Target>

    @Test func unknownCurrentPreservesExactOrderedChoices() {
        let row = Row(
            id: "first", title: "First", options: [" On ", "off", "ON"],
            current: nil, request: .first, unavailableReason: nil)
        #expect(row.id == "first")
        #expect(row.options == [" On ", "off", "ON"])
        #expect(row.current == nil)
        let outside = Row(
            id: "second", title: "Second", options: [],
            current: "unlisted observation", request: nil, unavailableReason: "Host refusal")
        #expect(outside.options.isEmpty)
        #expect(outside.current == "unlisted observation")
    }

    @Test func eachSelectionSendsOnlyItsExistingRequestAndExactOption() {
        let first = Row(
            id: "first", title: "First", options: ["off", " On "],
            current: "off", request: .first, unavailableReason: nil)
        let second = Row(
            id: "second", title: "Second", options: ["off", "on"],
            current: nil, request: .second, unavailableReason: nil)
        var requests: [Target] = []
        var options: [String] = []
        var refusals = 0
        for (row, option) in [(first, " On "), (second, "on"), (first, "off")] {
            row.select(
                option, interactionEnabled: true, currentSource: { true },
                onSelect: {
                    requests.append($0)
                    options.append($1)
                },
                onUnavailable: { _, _ in refusals += 1 })
        }
        #expect(requests == [.first, .second, .first])
        #expect(options == [" On ", "on", "off"])
        #expect(refusals == 0)
        #expect(second.current == nil)
    }

    @Test func missingRequestReportsOnlyTheHostReason() {
        var requests = 0
        var refusedIDs: [String] = []
        var reasons: [String?] = []
        for reason: String? in ["Host refusal", nil] {
            let row = Row(
                id: "unavailable", title: "Unavailable", options: ["on"],
                current: nil, request: nil, unavailableReason: reason)
            row.select(
                "on", interactionEnabled: true, currentSource: { true },
                onSelect: { _, _ in requests += 1 },
                onUnavailable: {
                    refusedIDs.append($0)
                    reasons.append($1)
                })
        }
        #expect(requests == 0)
        #expect(refusedIDs == ["unavailable", "unavailable"])
        #expect(reasons == ["Host refusal", nil])
    }

    @Test func interactionAndSourceGuardsRefuseBeforeAnyCallback() {
        var callbacks = 0
        var sourceCurrent = true
        let row = Row(
            id: "first", title: "First", options: ["on"],
            current: nil, request: .first, unavailableReason: nil)
        let select = { (enabled: Bool) in
            row.select(
                "on", interactionEnabled: enabled, currentSource: { sourceCurrent },
                onSelect: { _, _ in callbacks += 1 },
                onUnavailable: { _, _ in callbacks += 1 })
        }
        select(false)
        sourceCurrent = false
        select(true)
        #expect(callbacks == 0)
        sourceCurrent = true
        select(true)
        #expect(callbacks == 1)
    }

    @Test func unlistedOptionsAreNeverNormalizedOrSent() {
        let row = Row(
            id: "first", title: "First", options: [" On "],
            current: nil, request: .first, unavailableReason: nil)
        var callbacks = 0
        for option in ["On", "ON", "on", "", "off"] {
            row.select(
                option, interactionEnabled: true, currentSource: { true },
                onSelect: { _, _ in callbacks += 1 },
                onUnavailable: { _, _ in callbacks += 1 })
        }
        #expect(callbacks == 0)
    }

    @Test func reasonDoesNotInventAnAdmissionPolicyForAnExistingRequest() {
        let row = Row(
            id: "first", title: "First", options: ["on"],
            current: nil, request: .first, unavailableReason: "Host detail")
        var requests: [Target] = []
        row.select(
            "on", interactionEnabled: true, currentSource: { true },
            onSelect: { request, _ in requests.append(request) },
            onUnavailable: { _, _ in
                Issue.record("The supplied request remains the host's decision")
            })
        #expect(requests == [.first])
    }
}
