import Foundation
import Observation
import OpenCineAppKit
import Testing

@MainActor private final class SettingsAccountGate {
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func complete(_ value: Bool) { let captured = continuation; continuation = nil; captured?.resume(returning: value) }
}
@MainActor private final class SettingsAccountProbe {
    var connects = 0
    var begins = 0
    var restores = 0
    var successorConnects = 0
    var replaced = false
}
private struct SettingsAccountFailure: LocalizedError { let errorDescription: String? }

/// SIMULATED mirror of MonitorSettingsAccountModelTest; every native wait is manually completed.
@MainActor @Suite struct MonitorSettingsAccountModelTests {
    private func settled(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    private func actions(identity: String = "account", consent: Bool? = false,
        current: @escaping @MainActor () -> Bool = { true },
        connect: @escaping @MainActor () async throws -> Void = {},
        disconnect: @escaping @MainActor () -> Void = {},
        begin: (@MainActor (@escaping @MainActor () -> Bool) async -> MonitorSettingsInternetLease?)? = nil) -> MonitorSettingsAccountActions {
        .init(identity: identity, isCurrent: current, requiresInternetConsent: consent,
            connect: connect, disconnect: disconnect, beginInternet: begin, internetFailure: "route unavailable")
    }
    @Test func consentCancelDoesNotEnterNativeIO() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), probe = SettingsAccountProbe()
        model.bind(actions(consent: true, connect: { probe.connects += 1 }, begin: { _ in probe.begins += 1; return nil }))
        model.requestSignIn(); #expect(model.confirmationPresented)
        model.cancelConfirmation()
        for _ in 0..<10 { await Task.yield() }
        #expect(probe.connects == 0 && probe.begins == 0 && !model.busy)
    }
    @Test func staleConsentCannotBorrowSameIdentityAfterReplacement() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), probe = SettingsAccountProbe()
        let captured = actions(consent: true, connect: { probe.connects += 1 }, begin: { _ in probe.begins += 1; return nil })
        model.bind(captured); model.requestSignIn()
        withObservationTracking { _ = model.confirmationPresented } onChange: {
            MainActor.assumeIsolated {
                if !model.confirmationPresented {
                    model.bind(actions(identity: "replacement")); model.bind(captured)
                }
            }
        }
        model.confirmSignIn()
        for _ in 0..<10 { await Task.yield() }
        #expect(probe.connects == 0 && probe.begins == 0 && !model.busy)
    }
    @Test func intentionalRehostSameIdentityContinuesAcceptedOperation() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), gate = SettingsAccountGate(), probe = SettingsAccountProbe()
        let captured = actions(consent: true, connect: { probe.connects += 1 }, begin: { _ in
            probe.begins += 1
            return .init(isCurrent: { true }, wait: gate.wait, restore: { probe.restores += 1 })
        })
        model.bind(captured); model.requestSignIn(); model.confirmSignIn()
        #expect(await settled { gate.continuation != nil })
        model.bind(actions(consent: false, connect: { probe.successorConnects += 1 }))
        gate.complete(true)
        #expect(await settled { !model.busy })
        #expect(probe.begins == 1 && probe.connects == 1 && probe.successorConnects == 0 && probe.restores == 1)
    }
    @Test func replacementWhileRouteWaitRestoresOnlyCapturedLease() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), route = SettingsAccountGate(), successor = SettingsAccountGate()
        let probe = SettingsAccountProbe()
        model.bind(actions(consent: true, connect: { probe.connects += 1 }, begin: { _ in
            .init(isCurrent: { true }, wait: route.wait, restore: { probe.restores += 1 })
        }))
        model.requestSignIn(); model.confirmSignIn(); #expect(await settled { route.continuation != nil })
        model.bind(actions(identity: "successor", connect: { probe.successorConnects += 1; _ = await successor.wait() }))
        model.requestSignIn(); #expect(await settled { successor.continuation != nil })
        route.complete(true); #expect(await settled { probe.restores == 1 })
        #expect(model.busy && probe.connects == 0 && probe.successorConnects == 1)
        successor.complete(true); #expect(await settled { !model.busy })
    }
    @Test func predicateReentryRefusesOldConnectForTrueAndFalse() async {
        guard #available(macOS 14, *) else { return }
        for answer in [false, true] {
            let model = MonitorSettingsAccountModel(), probe = SettingsAccountProbe()
            let successor = actions(identity: "successor", connect: { probe.successorConnects += 1 })
            model.bind(actions(current: {
                if !probe.replaced { probe.replaced = true; model.bind(successor); return answer }
                return true
            }, connect: { probe.connects += 1 }))
            model.requestSignIn(); model.requestSignIn()
            #expect(await settled { probe.successorConnects == 1 && !model.busy })
            #expect(probe.connects == 0)
        }
    }
    @Test func busyPublicationCommitsReplacementBeforeOldTaskStarts() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), gate = SettingsAccountGate(), probe = SettingsAccountProbe()
        let successor = actions(identity: "successor", connect: { probe.successorConnects += 1; _ = await gate.wait() })
        model.bind(actions(connect: { probe.connects += 1 }))
        withObservationTracking { _ = model.busy } onChange: {
            MainActor.assumeIsolated {
                if model.busy && !probe.replaced { probe.replaced = true; model.bind(successor); model.requestSignIn() }
            }
        }
        model.requestSignIn(); #expect(await settled { gate.continuation != nil })
        #expect(probe.connects == 0 && probe.successorConnects == 1 && model.busy)
        gate.complete(true); #expect(await settled { !model.busy })
    }
    @Test func reportedAndUnknownNativeErrorsRemainDistinct() async {
        guard #available(macOS 14, *) else { return }
        for reason in [String?.none, "native authorization refused"] {
            let model = MonitorSettingsAccountModel()
            model.bind(actions(connect: { throw SettingsAccountFailure(errorDescription: reason) }))
            model.requestSignIn(); #expect(await settled { !model.busy })
            #expect(model.failed && model.failure == reason)
        }
    }
    @Test func browserLeaseCleanupWaitsForGenuineRetirement() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), probe = SettingsAccountProbe()
        model.bind(actions(consent: true, connect: { probe.connects += 1 }, begin: { _ in
            .init(isCurrent: { true }, wait: { true }, restore: { probe.restores += 1 }, cleanup: .onRetire)
        }))
        model.requestSignIn(); model.confirmSignIn(); #expect(await settled { !model.busy })
        #expect(probe.connects == 1 && probe.restores == 0)
        model.bind(actions(consent: false)); #expect(probe.restores == 0)
        model.retire(); #expect(await settled { probe.restores == 1 })
    }
    @Test func signOutRetiresNativeReceiptWithoutBorrowingSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), probe = SettingsAccountProbe()
        model.bind(actions(current: { !probe.replaced }, disconnect: { probe.replaced = true }))
        model.signOut(); #expect(model.accountRevision == 1)
        let successor = actions(identity: "successor")
        model.bind(actions(disconnect: { model.bind(successor) }))
        model.signOut(); #expect(model.accountRevision == 0)
    }
    @Test func routeAcquisitionAdmissionCannotBorrowSuccessor() async {
        guard #available(macOS 14, *) else { return }
        let model = MonitorSettingsAccountModel(), route = SettingsAccountGate(), probe = SettingsAccountProbe()
        model.bind(actions(consent: true, connect: { probe.connects += 1 }, begin: { admission in
            _ = await route.wait()
            guard admission() else { return nil }
            probe.begins += 1
            return .init(isCurrent: { true }, wait: { true }, restore: { probe.restores += 1 })
        }))
        model.requestSignIn(); model.confirmSignIn()
        #expect(await settled { route.continuation != nil })
        model.bind(actions(identity: "successor", connect: { probe.successorConnects += 1 }))
        model.requestSignIn()
        #expect(await settled { probe.successorConnects == 1 && !model.busy })
        route.complete(true)
        for _ in 0..<10 { await Task.yield() }
        #expect(probe.begins == 0 && probe.connects == 0 && probe.restores == 0 && probe.successorConnects == 1)
    }
}
