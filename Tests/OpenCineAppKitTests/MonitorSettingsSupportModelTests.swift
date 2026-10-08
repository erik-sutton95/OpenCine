import Foundation
import Observation
import OpenCineAppKit
import Testing

@MainActor private final class SettingsSupportGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func complete() { let captured = continuation; continuation = nil; captured?.resume() }
}
@MainActor private final class SettingsSupportProbe {
    var reports = 0
    var preparations = 0
    var opened: [URL] = []
    var completions: [Bool] = []
    var replaced = false
}

/// SIMULATED native report/browser replies are driven explicitly, without network or filesystem IO.
@MainActor @Suite struct MonitorSettingsSupportModelTests {
    private let first = URL(string: "https://example.test/first")!
    private let second = URL(string: "https://example.test/second")!
    private func destination(_ url: URL) -> MonitorSettingsBrowserDestination {
        .init(id: url.path, title: url.path, url: url, confirmationMessage: "Leave this source network?")
    }
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    private func actions(identity: String = "root", consent: Bool? = false,
        current: @escaping @MainActor () -> Bool = { true },
        report: @escaping @MainActor () async throws -> URL,
        prepare: @escaping @MainActor (@escaping @MainActor () -> Bool) async -> MonitorSettingsBrowserHandoff?,
        open: @escaping @MainActor (URL) async -> Bool = { _ in true }) -> MonitorSettingsSupportActions {
        .init(identity: identity, isCurrent: current, requiresInternetConsent: consent,
            makeReport: report, prepareBrowser: prepare, open: open, internetFailure: "internet unavailable")
    }
    @Test func consentCancellationDoesNotPrepareOrOpenBrowser() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsSupportModel(), probe = SettingsSupportProbe()
        model.bind(actions(consent: true, report: { first }, prepare: { _ in probe.preparations += 1; return nil },
            open: { probe.opened.append($0); return true }))
        model.request(destination(first)); #expect(model.destination?.url == first)
        model.cancelConfirmation()
        for _ in 0..<10 { await Task.yield() }
        #expect(probe.preparations == 0 && probe.opened.isEmpty && model.destination == nil)
    }
    @Test func staleReportCannotReplaceSuccessorSharePayload() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsSupportModel(), gate = SettingsSupportGate()
        model.bind(actions(report: { await gate.wait(); return first }, prepare: { _ in nil }))
        model.prepareReport(); #expect(await settled { gate.continuation != nil })
        model.bind(actions(identity: "successor", report: { second }, prepare: { _ in nil }))
        model.prepareReport(); #expect(await settled { model.reportURL == second })
        gate.complete()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.reportURL == second && !model.preparingReport && !model.reportFailed)
    }
    @Test func browserReplacementJoinsCapturedCleanupBeforeNewPreparation() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsSupportModel(), entered = SettingsSupportGate(), cleanup = SettingsSupportGate()
        let probe = SettingsSupportProbe()
        model.bind(actions(report: { first }, prepare: { admission in
            probe.preparations += 1
            await entered.wait()
            return .init(isCurrent: admission, complete: { accepted in probe.completions.append(accepted); await cleanup.wait() })
        }, open: { probe.opened.append($0); return true }))
        model.request(destination(first)); #expect(await settled { entered.continuation != nil })
        model.bind(actions(report: { second }, prepare: { admission in
            probe.preparations += 1; return .init(isCurrent: admission, complete: { probe.completions.append($0) })
        }, open: { probe.opened.append($0); return true }))
        model.request(destination(second)); entered.complete()
        #expect(await settled { cleanup.continuation != nil })
        #expect(probe.preparations == 1 && probe.opened.isEmpty && probe.completions == [false])
        cleanup.complete(); #expect(await settled { !model.preparingBrowser })
        #expect(probe.preparations == 2 && probe.opened == [second] && probe.completions == [false, true])
    }
    @Test func handoffPredicateReplacementCannotOpenSuccessorURL() async {
        guard #available(macOS 14, *) else { return }
        for answer in [false, true] {
            let model = MonitorSettingsSupportModel(), probe = SettingsSupportProbe()
            let successor = actions(identity: "successor", report: { second }, prepare: { _ in nil })
            model.bind(actions(report: { first }, prepare: { _ in
                .init(isCurrent: {
                    if !probe.replaced { probe.replaced = true; model.bind(successor) }; return answer
                }, complete: { probe.completions.append($0) })
            }, open: { probe.opened.append($0); return true }))
            model.request(destination(first)); #expect(await settled { !probe.completions.isEmpty })
            #expect(probe.opened.isEmpty && probe.completions == [false] && !model.preparingBrowser)
        }
    }
    @Test func canceledEnteredBrowserRefusesLateAcceptedHandoff() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsSupportModel(), gate = SettingsSupportGate(), probe = SettingsSupportProbe()
        model.bind(actions(report: { first }, prepare: { admission in
            .init(isCurrent: admission, complete: { probe.completions.append($0) })
        }, open: { probe.opened.append($0); await gate.wait(); return true }))
        model.request(destination(first)); #expect(await settled { gate.continuation != nil })
        model.retire(); gate.complete(); #expect(await settled { !probe.completions.isEmpty })
        #expect(probe.completions == [false] && !model.preparingBrowser && !model.browserFailed)
    }
    @Test func reportPublicationCannotOverwriteReentrantSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsSupportModel(), probe = SettingsSupportProbe()
        let successor = actions(identity: "successor", report: { second }, prepare: { _ in nil })
        model.bind(actions(report: { first }, prepare: { _ in nil }))
        withObservationTracking { _ = model.reportURL } onChange: {
            MainActor.assumeIsolated {
                if model.reportURL == first && !probe.replaced { probe.replaced = true; model.bind(successor); model.prepareReport() }
            }
        }
        model.prepareReport(); #expect(await settled { model.reportURL == second && !model.preparingReport })
    }
}
