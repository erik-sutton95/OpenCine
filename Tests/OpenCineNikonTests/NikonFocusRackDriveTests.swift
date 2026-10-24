import Foundation
import Testing

@testable import OpenCineNikon

@Suite("SIMULATED focus-rack drive sequencing")
struct NikonFocusRackDriveTests {
    @Test func currentRunStopNeverRearmsOrCancelsANewerIdentity() {
        let registry = NikonFocusRackRunRegistry()
        registry.requestStopCurrent()
        #expect(registry.prepare(runID: 1))
        let first = registry.receipt(runID: 1)
        registry.requestStopCurrent()
        #expect(first?.isStopRequested == true)
        #expect(!registry.prepare(runID: 1))
        #expect(registry.prepare(runID: 2))
        registry.requestStop(runID: 1)
        #expect(registry.receipt(runID: 2)?.isStopRequested == false)
    }

    @Test func incompleteSafetySnapshotIsNeverFresh() {
        #expect(throws: NikonFocusRackAccessError.self) {
            try NikonFocusRackSafetySnapshot(reported: PTPCameraPropertySnapshot())
        }
    }

    @Test func stoppedBeforeActivationSendsNothing() {
        var machine = NikonFocusRackDriveMachine()
        #expect(machine.next(stopRequested: true) == .finished(.cancelledBeforeActivation))
    }

    @Test func readinessDistinguishesCompletedAndUnfulfilledMovement() {
        for (response, outcome): (PTPResponseCode, NikonFocusRackDriveOutcome) in [
            (.ok, .complete), (.mfDriveStepEnd, .endOfTravel),
            (.mfDriveStepInsufficiency, .stepTooSmall),
        ] {
            var machine = NikonFocusRackDriveMachine()
            #expect(machine.next(stopRequested: false) == .activate)
            machine.received(.ok)
            #expect(machine.next(stopRequested: false) == .poll)
            machine.received(response)
            #expect(machine.next(stopRequested: false) == .finished(outcome))
        }
    }

    @Test func explicitActivationRefusalNeverRetries() {
        var machine = NikonFocusRackDriveMachine()
        #expect(machine.next(stopRequested: false) == .activate)
        machine.received(.accessDenied)
        #expect(machine.next(stopRequested: false) == .finished(.activationRejected(0x2013)))
    }

    @Test func cancelledMoveRequiresCancelAndReadiness() {
        var machine = NikonFocusRackDriveMachine()
        #expect(machine.next(stopRequested: false) == .activate)
        machine.received(.ok)
        #expect(machine.next(stopRequested: true) == .cancel)
        machine.received(.ok)
        #expect(machine.next(stopRequested: true) == .poll)
        machine.received(.ok)
        #expect(machine.next(stopRequested: true) == .finished(.cancelledReady))
    }

    @Test func cancellationRefusalAndReadinessFailureRemainUnconfirmed() {
        for failsAtCancel in [true, false] {
            var machine = NikonFocusRackDriveMachine()
            _ = machine.next(stopRequested: false)
            machine.received(.ok)
            #expect(machine.next(stopRequested: true) == .cancel)
            if failsAtCancel {
                machine.received(.accessDenied)
            } else {
                machine.received(.ok)
                #expect(machine.next(stopRequested: true) == .poll)
                machine.transportFailed()
            }
            #expect(machine.next(stopRequested: true) == .finished(.cancelledUnconfirmed))
        }
    }

    @Test func pollCeilingCleansUpButNeverClaimsKnownDisplacement() {
        var machine = NikonFocusRackDriveMachine()
        _ = machine.next(stopRequested: false)
        machine.received(.ok)
        for index in 0..<NikonFocusRackDriveMachine.readinessPollLimit {
            #expect(machine.next(stopRequested: false) == .poll)
            machine.received(.deviceBusy)
            if index + 1 < NikonFocusRackDriveMachine.readinessPollLimit {
                #expect(
                    machine.next(stopRequested: false)
                        == .wait(seconds: index < 6 ? 0.02 : 0.12))
            }
        }
        #expect(machine.next(stopRequested: false) == .cancel)
        machine.received(.ok)
        #expect(machine.next(stopRequested: false) == .poll)
        machine.received(.ok)
        #expect(machine.next(stopRequested: false) == .finished(.uncertain))
    }

    @Test func transportFailureCannotBeConvertedIntoNoMovementByLateStop() {
        var machine = NikonFocusRackDriveMachine()
        #expect(machine.next(stopRequested: false) == .activate)
        machine.transportFailed()
        #expect(machine.next(stopRequested: true) == .finished(.uncertain))
    }

    @Test func replacedAndStoppedRunsCannotBeRearmed() throws {
        let early = NikonFocusRackRunRegistry()
        early.requestStop(runID: 1)
        #expect(!early.prepare(runID: 1))
        #expect(early.prepare(runID: 2))
        let runs = NikonFocusRackRunRegistry()
        #expect(!runs.prepare(runID: 0))
        #expect(runs.prepare(runID: 1))
        let first = try #require(runs.receipt(runID: 1))
        #expect(runs.prepare(runID: 2))
        #expect(first.isStopRequested)
        #expect(runs.receipt(runID: 1) == nil)
        runs.requestStop(runID: 1)
        let second = try #require(runs.receipt(runID: 2))
        #expect(!second.isStopRequested)
        runs.requestStop(runID: 2)
        #expect(second.isStopRequested)
        #expect(!runs.prepare(runID: 2))
        #expect(!runs.prepare(runID: 1))
    }

    @Test func driveAndStopConfirmationPollsAreBounded() {
        var machine = NikonFocusRackDriveMachine()
        #expect(machine.next(stopRequested: false) == .activate)
        machine.received(.ok)
        for index in 0..<NikonFocusRackDriveMachine.readinessPollLimit {
            #expect(machine.next(stopRequested: false) == .poll)
            machine.received(.deviceBusy)
            if index + 1 < NikonFocusRackDriveMachine.readinessPollLimit {
                #expect(
                    machine.next(stopRequested: false)
                        == .wait(seconds: index < 6 ? 0.02 : 0.12))
            }
        }
        #expect(machine.next(stopRequested: false) == .cancel)
        machine.received(.ok)
        for index in 0..<NikonFocusRackDriveMachine.readinessPollLimit {
            #expect(machine.next(stopRequested: true) == .poll)
            machine.received(.deviceBusy)
            if index + 1 < NikonFocusRackDriveMachine.readinessPollLimit {
                #expect(
                    machine.next(stopRequested: true)
                        == .wait(seconds: index < 6 ? 0.02 : 0.12))
            }
        }
        #expect(machine.next(stopRequested: true) == .finished(.cancelledUnconfirmed))
    }

    @Test func earlyPollsPreserveTheOldSleepBudgetInBothReadinessPhases() throws {
        var machine = NikonFocusRackDriveMachine()
        _ = machine.next(stopRequested: false)
        machine.received(.ok)
        for confirming in [false, true] {
            var waits: [Double] = []
            for index in 0..<NikonFocusRackDriveMachine.readinessPollLimit {
                #expect(machine.next(stopRequested: false) == .poll)
                machine.received(.deviceBusy)
                if index + 1 < NikonFocusRackDriveMachine.readinessPollLimit {
                    guard case .wait(let seconds) = machine.next(stopRequested: false) else {
                        Issue.record("Busy must yield before polling again")
                        return
                    }
                    waits.append(seconds)
                }
            }
            #expect(waits.prefix(6).allSatisfy { $0 == 0.02 })
            #expect(waits.dropFirst(6).allSatisfy { $0 == 0.12 })
            #expect(abs(waits.reduce(0, +) - 1.32) < 1e-9)
            if !confirming {
                #expect(machine.next(stopRequested: false) == .cancel)
                machine.received(.ok)
            }
        }
        #expect(machine.next(stopRequested: false) == .finished(.uncertain))
    }

    @Test func stopPreemptsAnEarlyBusyWaitWithoutAnotherDrivePoll() {
        var machine = NikonFocusRackDriveMachine()
        _ = machine.next(stopRequested: false)
        machine.received(.ok)
        #expect(machine.next(stopRequested: false) == .poll)
        machine.received(.deviceBusy)
        #expect(machine.next(stopRequested: true) == .cancel)
        machine.received(.ok)
        #expect(machine.next(stopRequested: true) == .poll)
        machine.received(.deviceBusy)
        #expect(machine.next(stopRequested: true) == .wait(seconds: 0.02))
        #expect(machine.next(stopRequested: true) == .poll)
        machine.received(.ok)
        #expect(machine.next(stopRequested: true) == .finished(.cancelledReady))
    }

    @Test func cancelRefusalAndTransportFailurePreserveUnconfirmedStop() {
        var refused = NikonFocusRackDriveMachine()
        _ = refused.next(stopRequested: false)
        refused.received(.ok)
        #expect(refused.next(stopRequested: true) == .cancel)
        refused.received(.accessDenied, rawResponseCode: 0xAFFF)
        #expect(refused.next(stopRequested: true) == .finished(.cancelledUnconfirmed))

        for confirming in [false, true] {
            var failed = NikonFocusRackDriveMachine()
            _ = failed.next(stopRequested: false)
            failed.received(.ok)
            _ = failed.next(stopRequested: true)
            if confirming { failed.received(.ok) }
            failed.transportFailed()
            #expect(failed.next(stopRequested: true) == .finished(.cancelledUnconfirmed))
        }
    }

    @Test func fastCadenceKeepsTheSameWaitBudgetAndTerminalCancellationEvidence() throws {
        var machine = NikonFocusRackDriveMachine(cadence: .fastExperimental)
        #expect(machine.next(stopRequested: false) == .activate)
        machine.received(.ok)
        for confirming in [false, true] {
            var waits: [Double] = []
            for index in 0..<35 {
                #expect(machine.next(stopRequested: confirming) == .poll)
                machine.received(.deviceBusy)
                if index < 34 {
                    guard case .wait(let seconds) = machine.next(stopRequested: confirming) else {
                        Issue.record("Busy must yield before the next readiness transaction")
                        return
                    }
                    waits.append(seconds)
                }
            }
            #expect(waits.count == 34)
            #expect(waits.prefix(24).allSatisfy { $0 == 0.005 })
            #expect(waits.dropFirst(24).allSatisfy { $0 == 0.12 })
            #expect(abs(waits.reduce(0, +) - 1.32) < 1e-9)
            if !confirming {
                #expect(machine.next(stopRequested: false) == .cancel)
                machine.received(.ok)
            }
        }
        #expect(machine.next(stopRequested: true) == .finished(.cancelledUnconfirmed))
    }

    @Test func fastCadenceStopPreemptsTheFiveMillisecondWait() {
        var machine = NikonFocusRackDriveMachine(cadence: .fastExperimental)
        _ = machine.next(stopRequested: false)
        machine.received(.ok)
        #expect(machine.next(stopRequested: false) == .poll)
        machine.received(.deviceBusy)
        #expect(machine.next(stopRequested: true) == .cancel)
        machine.received(.ok)
        #expect(machine.next(stopRequested: true) == .poll)
        machine.received(.ok)
        #expect(machine.next(stopRequested: true) == .finished(.cancelledReady))
    }

    @Test func outcomesRoundTripAndPinTheAndroidWire() throws {
        let cases: [NikonFocusRackDriveOutcome] = [
            .complete, .endOfTravel, .stepTooSmall, .cancelledReady, .cancelledUnconfirmed,
            .uncertain, .cancelledBeforeActivation, .activationRejected(0x2019),
        ]
        #expect(cases.map(\.wireValue) == [0, 1, 2, 3, 4, 5, 6, 0x12019])
        for outcome in cases {
            #expect(
                try JSONDecoder().decode(
                    NikonFocusRackDriveOutcome.self, from: JSONEncoder().encode(outcome)) == outcome
            )
        }
    }
}
