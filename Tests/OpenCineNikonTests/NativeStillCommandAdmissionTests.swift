#if canImport(Darwin) && canImport(os)
    import Foundation
    import OpenCineCore
    import Testing

    @testable import OpenCineNikon

    /// SIMULATED transaction scheduling over the real NativeCameraSession still-release methods.
    /// Exact request bytes are asserted; this fixture provides no SDK or camera qualification.
    @MainActor @Suite struct NativeStillCommandAdmissionTests {
        @Test func currentAndDirectReleasesPreserveAdvertisedOperationAndFocusParameters()
            async throws
        {
            for operation: UInt16 in [0x9207, 0x100E] {
                let transport = Transport(captureOperation: operation)
                let session = try await makeSession(transport)
                let admission = NikonCommandAdmission(
                    owner: try #require(session.commandOwner), isCurrent: { true })
                await transport.clear()
                try await session.initiateStillCapture(preserveFocus: true, admission: admission)
                try await session.initiateStillCapture(preserveFocus: false)
                try await session.terminateStillCapture(admission: admission)
                try await session.changeCameraMode(remote: true, admission: admission)
                let calls = await transport.calls
                #expect(
                    calls.map { $0.operation.rawValue } == [operation, operation, 0x920C, 0x90C2])
                #expect(calls[0].parameters == (operation == 0x9207 ? [0xFFFF_FFFF, 0] : []))
                #expect(calls[1].parameters == (operation == 0x9207 ? [0xFFFF_FFFE, 0] : []))
                #expect(calls[2].parameters == [0, 0] && calls[3].parameters == [1])
                #expect(calls.allSatisfy { $0.phase.rawValue == 1 && $0.deadline == .seconds(15) })
                session.close()
                #expect(await transport.calls.count == 4)
            }
        }

        @Test func wrongOwnerAndRevokedReceiptsRefuseWhileDirectCommandsRemainAvailable()
            async throws
        {
            let transport = Transport()
            let session = try await makeSession(transport)
            let gate = ReceiptGate()
            let current = NikonCommandAdmission(
                owner: try #require(session.commandOwner), isCurrent: { gate.isCurrent })
            let other = NikonCommandAdmission(owner: NikonCommandOwner(), isCurrent: { true })
            await transport.clear()
            #expect(
                await wasAuthorityRefusal {
                    try await session.initiateStillCapture(preserveFocus: true, admission: other)
                })
            gate.revoke()
            #expect(
                await wasAuthorityRefusal {
                    try await session.initiateStillCapture(preserveFocus: true, admission: current)
                })
            #expect(
                await wasAuthorityRefusal {
                    try await session.terminateStillCapture(admission: current)
                })
            #expect(
                await wasAuthorityRefusal {
                    try await session.changeCameraMode(remote: true, admission: current)
                })
            #expect(await transport.calls.isEmpty)
            try await session.initiateStillCapture()
            try await session.terminateStillCapture()
            #expect(
                await transport.calls.map(\.operation) == [
                    .initiateCaptureRecInMedia, .terminateCapture,
                ])
            session.close()
            #expect(!current.isCurrent)
            #expect(await transport.calls.count == 2)
        }

        @Test func waitingFirstSendRefusesAndEnteredReleaseStillCompletesItsReadinessAndCleanup()
            async throws
        {
            for hold in [Transport.Hold.beforeSend, .afterSend] {
                let transport = Transport()
                let session = try await makeSession(transport)
                let gate = ReceiptGate()
                let admission = NikonCommandAdmission(
                    owner: try #require(session.commandOwner), isCurrent: { gate.isCurrent })
                await transport.clear(hold: hold)
                let release = Task {
                    do {
                        try await session.initiateStillCapture(
                            preserveFocus: true, admission: admission)
                        return true
                    } catch NativeCameraSessionError.commandAuthorityExpired { return false }
                }
                await transport.waitUntilHeld()
                let entered = await transport.calls.count
                #expect(entered == (hold == .beforeSend ? 0 : 1))
                gate.revoke()
                await transport.release()
                #expect(try await release.value == (hold == .afterSend))
                #expect(await transport.calls.count == entered)
                if hold == .afterSend {
                    // The already accepted transaction's observation and bracket cleanup use the
                    // original direct path. Receipt retirement cannot strand an entered release.
                    _ = try await session.pollStillReleaseReadiness()
                    try await session.changeCameraMode(remote: false)
                    let calls = await transport.calls
                    #expect(
                        calls.map(\.operation) == [
                            .initiateCaptureRecInMedia, .deviceReady, .changeCameraMode,
                        ])
                    #expect(calls.last?.parameters == [0])
                }
                let beforeClose = await transport.calls.count
                session.close()
                #expect(await transport.calls.count == beforeClose)
            }
        }

        @Test func memberRetirementAtNativeFirstSendPreservesEnteredWriteAndReadback() async throws {
            for hold in [Transport.Hold.beforeSend, .afterSend] {
                let transport = Transport()
                let session = try await makeSession(transport)
                let gate = ReceiptGate()
                let admission = NikonCommandAdmission(owner: try #require(session.commandOwner), isCurrent: { gate.isCurrent })
                let member = NikonMemberControl(serialNumber: "SIMULATED-MEMBER",
                    facts: NikonCameraSessionTests.movieFacts(), commandOwner: session.commandOwner,
                    isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
                await transport.clear(hold: hold)
                let approved = member.session.request(.set(.iso(.manual(1600))), admission: admission)
                #expect(approved.stage == .admitted)
                let service = Task { await member.service(session) }
                await transport.waitUntilHeld()
                #expect(await transport.calls.count == (hold == .beforeSend ? 0 : 1))
                gate.revoke()
                await transport.release()
                _ = await service.value
                let calls = await transport.calls
                #expect(calls.map(\.operation) == (hold == .beforeSend ? [] : [.setDevicePropValue, .getDevicePropValue]))
                if hold == .afterSend {
                    #expect(calls[0].parameters == [0xD1AA] && calls[1].parameters == [0xD1AA])
                }
                #expect(member.session.receipt(of: approved.operation)?.stage ==
                    (hold == .beforeSend ? .rejected(.authorityExpired) : .confirmed))
                #expect(!member.hasQueuedCommands)
                session.close()
            }
        }

        @Test func memberNativeWaiterRechecksPublishedAuthorityDomainEpochAndClose() async throws {
            for change in ["authority", "domain", "epoch", "close"] {
                let transport = Transport()
                let native = try await makeSession(transport)
                let member = NikonMemberControl(serialNumber: "SIMULATED-MEMBER",
                    facts: NikonCameraSessionTests.movieFacts(), commandOwner: native.commandOwner,
                    isCameraRefusal: NativeCameraSessionError.isCameraRefusal)
                let source = try #require(member.session)
                let command = CameraCommand(.set(.whiteBalance(.preset("Sunny"))),
                    preconditions: CommandPreconditions(source.refresh()))
                let admission = NikonCommandAdmission(owner: try #require(native.commandOwner)) {
                    source.commandSnapshot.rejection(of: command, at: .now()) == nil
                }
                let approved = source.submit(command, admission: admission)
                #expect(approved.stage == .admitted)
                await transport.clear(hold: .beforeSend)
                let service = Task { await member.service(native) }
                await transport.waitUntilHeld()
                #expect(await transport.calls.isEmpty)
                switch change {
                case "authority": member.update { $0.holdsControl = false }
                case "domain": member.update { $0.whiteBalancePresets = ["Auto"] }
                case "epoch":
                    member.update { $0.connection = .recovering(ConnectionAttemptID()) }
                    member.update { $0.connection = .ready }
                default: source.close(.replaced)
                }
                #expect(source.commandSnapshot.rejection(of: command, at: .now()) != nil)
                await transport.release()
                _ = await service.value
                #expect(await transport.calls.isEmpty)
                let final = source.receipt(of: approved.operation)?.stage
                #expect(final == (change == "epoch" || change == "close" ? .outcomeUnknown : .rejected(.authorityExpired)))
                #expect(!member.hasQueuedCommands)
                native.close()
            }
        }

        private func makeSession(_ transport: Transport) async throws -> NativeCameraSession {
            try await NativeCameraSession.establish(
                transport: transport, host: "usb:watch-admission", cameraName: "Same name",
                requestPairing: false)
        }
        private func wasAuthorityRefusal(_ action: () async throws -> Void) async -> Bool {
            do {
                try await action()
                return false
            } catch NativeCameraSessionError.commandAuthorityExpired { return true } catch {
                Issue.record(error)
                return false
            }
        }
    }

    private final class ReceiptGate: @unchecked Sendable {
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

    private actor Transport: CameraTransport {
        enum Hold: Equatable, Sendable { case beforeSend, afterSend }
        struct Call: Sendable {
            let operation: PTPOperationCode
            let parameters: [UInt32]
            let phase: PTPDataPhase
            let deadline: Duration?
        }
        nonisolated let kind: CameraTransportKind = .usb
        private let captureOperation: UInt16
        private(set) var calls: [Call] = []
        private var propertyBytes: [UInt32: Data] = [:]
        private var hold: Hold?
        private var held = false
        private var waiting: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?
        init(captureOperation: UInt16 = 0x9207) { self.captureOperation = captureOperation }
        func clear(hold: Hold? = nil) {
            calls = []
            self.hold = hold
            held = false
        }
        func executeTransaction(
            operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
            dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?
        ) async throws -> PTPIPTransactionResult {
            calls.append(
                .init(
                    operation: operationCode, parameters: parameters, phase: dataPhase,
                    deadline: deadline))
            if operationCode == .setDevicePropValue || operationCode == .setDevicePropValueEx,
                let property = parameters.first, let dataOut {
                propertyBytes[property] = dataOut
            }
            let data: Data
            if operationCode == .getDeviceInfo {
                data = deviceInfo(captureOperation: captureOperation)
            } else if operationCode == .getDevicePropValue || operationCode == .getDevicePropValueEx {
                data = parameters.first.flatMap { propertyBytes[$0] } ?? Data()
            } else {
                data = Data()
            }
            let payload =
                ByteCoding.uint16LE(PTPResponseCode.ok.rawValue)
                + ByteCoding.uint32LE(transactionID ?? 1)
            return PTPIPTransactionResult(
                operationResponse: try PTPOperationResponse(payloadBytes: payload),
                data: data)
        }
        func executeTransaction(
            operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
            dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?,
            admission: NikonCommandAdmission
        ) async throws -> PTPIPTransactionResult {
            let holding = hold
            hold = nil
            if holding == .beforeSend { await pause() }
            try admission.requireCurrent()
            let result = try await executeTransaction(
                operationCode: operationCode, transactionID: transactionID, parameters: parameters,
                dataPhase: dataPhase, dataOut: dataOut, deadline: deadline)
            if holding == .afterSend { await pause() }
            return result
        }
        private func pause() async {
            await withCheckedContinuation {
                waiting = $0
                held = true
                entered?.resume()
                entered = nil
            }
        }
        func waitUntilHeld() async {
            if held { return }
            await withCheckedContinuation { entered = $0 }
        }
        func release() {
            waiting?.resume()
            waiting = nil
        }
        func nextEvent() async throws -> PTPEvent {
            throw NativeCameraSessionError.connectionClosed
        }
        nonisolated func close() {}
    }

    private func deviceInfo(captureOperation: UInt16) -> Data {
        var bytes: [UInt8] = [100, 0, 10, 0, 0, 0, 100, 0]
        bytes += [0, 0, 0]  // Empty vendor extension string and functional mode.
        bytes += ByteCoding.uint32LE(1) + ByteCoding.uint16LE(captureOperation)
        for _ in 0..<4 { bytes += ByteCoding.uint32LE(0) }
        for value in ["Nikon", "ZR", "1.0", "WATCH-RECEIPT"] {
            bytes.append(UInt8(value.utf16.count + 1))
            for unit in value.utf16 { bytes += ByteCoding.uint16LE(unit) }
            bytes += [0, 0]
        }
        return Data(bytes)
    }
#endif
