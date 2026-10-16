import OpenCineAppKit
import Testing

/// SIMULATED operator actions. No transport, camera command or hardware is involved.
@MainActor
@Suite struct OperatorConsentTests {
    @available(macOS 14, *)
    @Test func aConfirmationIsConsumedBeforeCallingTheHost() {
        let owner = OperatorConsent()
        var admitted = 0
        let request = OperatorConsentRequest(
            title: "Use camera?", message: "Another operator loses their session.",
            confirmTitle: "Continue",
            onConfirm: { admitted += 1 }, onCancel: {})
        owner.present(request, source: "source-1")
        owner.confirm(request.id)
        owner.confirm(request.id)
        owner.present(request, source: "source-1")
        owner.confirm(request.id)
        #expect(admitted == 1)
        #expect(owner.pending == nil)
    }

    @available(macOS 14, *)
    @Test func cancellingNeverAdmitsAndOnlyCancelsOnce() {
        let owner = OperatorConsent()
        var admitted = 0
        var cancelled = 0
        let request = OperatorConsentRequest(
            title: "Use camera?", message: "Consent required", confirmTitle: "Continue",
            onConfirm: { admitted += 1 }, onCancel: { cancelled += 1 })
        owner.present(request, source: "source-1")
        owner.cancel(request.id)
        owner.confirm(request.id)
        owner.cancel(request.id)
        #expect(admitted == 0 && cancelled == 1)
    }

    @available(macOS 14, *)
    @Test func aSupersededAlertCannotConfirmOrDismissItsSuccessor() {
        let owner = OperatorConsent()
        var actions: [String] = []
        let first = OperatorConsentRequest(
            title: "First", message: "First source", confirmTitle: "Continue",
            onConfirm: { actions.append("first") }, onCancel: { actions.append("cancel-first") })
        let second = OperatorConsentRequest(
            title: "Second", message: "Second source", confirmTitle: "Continue",
            onConfirm: { actions.append("second") }, onCancel: { actions.append("cancel-second") })
        owner.present(first, source: "source-1")
        owner.present(second, source: "source-2")
        owner.confirm(first.id)
        owner.cancel(first.id)
        #expect(owner.pending?.id == second.id)
        #expect(actions.isEmpty)
        owner.confirm(second.id)
        #expect(actions == ["second"])
    }

    @available(macOS 14, *)
    @Test func retirementSendsNoCommandAndRejectsLateConfirmation() {
        let owner = OperatorConsent()
        var actions = 0
        let request = OperatorConsentRequest(
            title: "Use camera?", message: "Consent required", confirmTitle: "Continue",
            onConfirm: { actions += 1 }, onCancel: { actions += 1 })
        owner.present(request, source: "source-1")
        owner.retire(source: "unrelated")
        #expect(owner.pending?.id == request.id)
        owner.retire(source: "source-1")
        owner.confirm(request.id)
        #expect(owner.pending == nil && actions == 0)
    }

    @available(macOS 14, *)
    @Test func aSourceThatRetiredBeforeItsDismissalCannotBeAdmitted() {
        let owner = OperatorConsent()
        var current = true
        var actions = 0
        let request = OperatorConsentRequest(
            title: "Use camera?", message: "Consent required", confirmTitle: "Continue",
            onConfirm: { actions += 1 }, onCancel: { actions += 1 })
        owner.present(request, source: "source-1", isCurrent: { current })
        current = false
        owner.confirm(request.id)
        #expect(owner.pending == nil && actions == 0)
    }
}
