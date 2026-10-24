import Foundation
import OpenCineNikon
import Testing

@testable import OpenCineNikonAndroid

@Suite("SIMULATED focus-rack wire execution")
struct FocusRackDriveTests {
    @Test func nativeAccessReadsFreshTypedSafetyAndRejectsBusyFinalReadiness() async throws {
        for ready in [true, false] {
            var options = FakeZRServer.Options()
            if !ready { options.mfDriveReadinessResponseCode = PTPResponseCode.deviceBusy.rawValue }
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(server)
            defer { session.disconnect() }
            let access = session.focusRackAccess { true }
            do {
                let safety = try await access.refreshSafety()
                #expect(ready)
                #expect(!safety.focusMode.isEmpty && !safety.lens.isEmpty)
            } catch { #expect(!ready) }
            #expect(server.receivedOperations().last == .deviceReady)
        }
    }

    @Test func nativeAccessAuthorityRevocationAfterActivationStillConfirmsCancellation()
        async throws
    {
        let authority = AccessAuthority()
        var options = FakeZRServer.Options()
        options.onMFDriveActivation = { authority.revoke() }
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        let access = session.focusRackAccess { authority.isCurrent }
        #expect(access.prepareRun(1))
        #expect(await access.driveChunk(1, false, 16) == .cancelledReady)
        #expect(server.receivedOperations().suffix(3) == [.mfDrive, .afDriveCancel, .deviceReady])
        #expect(!access.prepareRun(2))
        #expect(await access.driveChunk(1, false, 16) == .cancelledBeforeActivation)
    }

    @Test func nativeActiveStopCatchesRunsPreparedOutsideKotlin() async throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        let access = session.focusRackAccess { true }
        #expect(access.prepareRun(1))
        session.requestActiveFocusRackStop()
        #expect(await access.driveChunk(1, false, 16) == .cancelledBeforeActivation)
        #expect(!server.receivedOperations().contains(.mfDrive))
    }

    @Test func targetedSafetyRefreshReadsNoBootstrapDescriptorsOrStorage() async throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        let start = server.receivedRequests().count
        let refreshed = try await session.focusRackAccess { true }.refreshSafety()
        #expect(!refreshed.focusMode.isEmpty)
        #expect(!refreshed.lens.isEmpty)
        let requests = Array(server.receivedRequests().dropFirst(start))
        #expect(
            requests.dropLast().map { $0.parameters.first } == [
                PTPPropertyCode.liveViewSelector.rawValue, PTPPropertyCode.movieFocusMode.rawValue,
                PTPPropertyCode.movieFocusMeteringMode.rawValue,
                PTPPropertyCode.movieAFSubjectDetection.rawValue,
                PTPPropertyCode.focalLength.rawValue, PTPPropertyCode.lensFocalMin.rawValue,
                PTPPropertyCode.lensFocalMax.rawValue, PTPPropertyCode.lensApertureMin.rawValue,
            ])
        #expect(
            requests.dropLast().allSatisfy {
                [.getDevicePropValue, .getDevicePropValueEx].contains($0.operation)
            })
        #expect(requests.last?.operation == .deviceReady)
    }

    @Test func busyOrRefusedFinalReadinessNeverPublishesTheSafetyBurst() async throws {
        for response in [PTPResponseCode.deviceBusy, .accessDenied] {
            var options = FakeZRServer.Options()
            options.mfDriveReadinessResponseCode = response.rawValue
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(server)
            defer { session.disconnect() }
            await #expect(throws: NikonFocusRackAccessError.self) {
                try await session.focusRackAccess { true }.refreshSafety()
            }
            #expect(server.receivedOperations().last == .deviceReady)
            #expect(server.receivedOperations().filter { $0 == .deviceReady }.count == 1)
        }
    }

    @Test func unknownSafetySelectorNeverPromotesRetainedMovieModeToFresh() async throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        let seeded = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.batteryLevel.rawValue))
        #expect(seeded.properties.batteryPercent == 80)
        let access = session.focusRackAccess { true }
        let first = try await access.refreshSafety()
        #expect(first.movieMode)
        server.setCameraProperty(.liveViewSelector, data: Data([0xFF]))
        await #expect(throws: NikonFocusRackAccessError.self) {
            try await access.refreshSafety()
        }
        server.setCameraProperty(.liveViewSelector, data: Data([0]))
        let restored = try await access.refreshSafety()
        #expect(!restored.movieMode)
        // Safety reads do not replace the monitor's unrelated retained readings.
        let retained = session.refreshAndroidPropertySnapshot(
            .propertyChanged(PTPPropertyCode.batteryLevel.rawValue))
        #expect(retained.properties.batteryPercent == seeded.properties.batteryPercent)
    }

    @Test func shortSafetyReadNeverPromotesRetainedLensDataToFresh() async throws {
        var options = FakeZRServer.Options()
        options.shortPropertyCodesAfterFirstRead = [PTPPropertyCode.lensFocalMax.rawValue]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        let access = session.focusRackAccess { true }
        _ = try await access.refreshSafety()
        await #expect(throws: NikonFocusRackAccessError.self) {
            try await access.refreshSafety()
        }
    }

    @Test func unsupportedSafetyFactFailsTheWholeFreshnessContract() async throws {
        var options = FakeZRServer.Options()
        options.unsupportedPropertyCodes = [PTPPropertyCode.movieFocusMode.rawValue]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        await #expect(throws: NikonFocusRackAccessError.self) {
            try await session.focusRackAccess { true }.refreshSafety()
        }
    }

    private func connect(_ server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000,
            strategy: .savedProfile)
    }

    @Test func optedInAccessSendsExactEightyPulseChunksAndKeepsStopAuthority() async throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        let access = session.focusRackAccess(cadence: .fastExperimental) { true }
        #expect(access.prepareRun(1))
        #expect(await access.driveChunk(1, true, 80) == .complete)
        #expect(server.receivedRequests().last { $0.operation == .mfDrive }?.parameters == [1, 80])
        access.requestStop(1)
        #expect(await access.driveChunk(1, false, 80) == .cancelledBeforeActivation)
        #expect(server.receivedOperations().filter { $0 == .mfDrive }.count == 1)
    }

    @Test func preparedChunkCompletesWithExactDirectionAndAmount() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        #expect(session.prepareFocusRackRun(runID: 1))
        #expect(
            session.focusRackDrive(
                runID: 1, towardNear: true, pulses: 40)
                == .complete)
        let requests = server.receivedRequests()
        #expect(requests.last { $0.operation == .mfDrive }?.parameters == [1, 40])
        #expect(requests.suffix(2).map(\.operation) == [.mfDrive, .deviceReady])
    }

    @Test func stoppedAndSupersededRunsNeverSendActivation() throws {
        let server = try FakeZRServer()
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        #expect(session.prepareFocusRackRun(runID: 1))
        session.requestFocusRackStop(runID: 1)
        #expect(
            session.focusRackDrive(runID: 1, towardNear: false, pulses: 40)
                == .cancelledBeforeActivation)
        #expect(session.prepareFocusRackRun(runID: 2))
        #expect(
            session.focusRackDrive(runID: 1, towardNear: false, pulses: 40)
                == .cancelledBeforeActivation)
        #expect(!server.receivedOperations().contains(.mfDrive))
    }

    @Test func activationRefusalAndInsufficientStepRemainDistinct() throws {
        for refuses in [true, false] {
            var options = FakeZRServer.Options()
            if refuses {
                options.mfDriveResponseCode = PTPResponseCode.accessDenied.rawValue
            } else {
                options.mfDriveReadinessResponseCode =
                    PTPResponseCode.mfDriveStepInsufficiency.rawValue
            }
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(server)
            defer { session.disconnect() }
            #expect(session.prepareFocusRackRun(runID: 1))
            #expect(
                session.focusRackDrive(runID: 1, towardNear: false, pulses: 1)
                    == (refuses ? .activationRejected(0x2013) : .stepTooSmall))
            #expect(server.receivedOperations().filter { $0 == .mfDrive }.count == 1)
        }
    }

    @Test func stopDuringActivationCancelsAtTheNextBoundaryThenConfirmsReady() throws {
        for confirms in [true, false] {
            let receipt = SessionReceipt()
            var options = FakeZRServer.Options()
            options.onMFDriveActivation = { receipt.stop() }
            if !confirms {
                options.afDriveCancelResponseCode = PTPResponseCode.accessDenied.rawValue
            }
            let server = try FakeZRServer(options: options)
            defer { server.stop() }
            let session = try connect(server)
            defer { session.disconnect() }
            receipt.install(session)
            #expect(session.prepareFocusRackRun(runID: 1))
            #expect(
                session.focusRackDrive(runID: 1, towardNear: false, pulses: 80)
                    == (confirms ? .cancelledReady : .cancelledUnconfirmed))
            let wire = server.receivedOperations().filter {
                [.mfDrive, .afDriveCancel, .deviceReady].contains($0)
            }
            #expect(
                wire
                    == (confirms
                        ? [.mfDrive, .afDriveCancel, .deviceReady] : [.mfDrive, .afDriveCancel]))
        }
    }

    @Test func lostActivationResponseReportsUnknownDisplacement() throws {
        var options = FakeZRServer.Options()
        options.disconnectsOnMFDrive = true
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(server)
        defer { session.disconnect() }
        #expect(session.prepareFocusRackRun(runID: 1))
        #expect(session.focusRackDrive(runID: 1, towardNear: false, pulses: 80) == .uncertain)
        #expect(server.receivedOperations().filter { $0 == .mfDrive }.count == 1)
    }
}

private final class SessionReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var session: PTPIPClientSession?
    func install(_ session: PTPIPClientSession) {
        lock.lock()
        self.session = session
        lock.unlock()
    }
    func stop() {
        lock.lock()
        let current = session
        lock.unlock()
        current?.requestFocusRackStop(runID: 1)
    }
}

private final class AccessAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isCurrent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    func revoke() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
