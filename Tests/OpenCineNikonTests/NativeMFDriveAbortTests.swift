#if canImport(Darwin) && canImport(os)
    import Foundation
    import OpenCineCore
    import Testing

    @testable import OpenCineNikon

    /// SIMULATED focus-by-wire body over the real NativeCameraSession drive and AF-area methods.
    /// The fixture refuses to send for a cancelled task, as `PTPIPTransport` and `USBCameraTransport`
    /// do, and holds `ChangeAfArea` busy until a `DeviceReady` reads the drive's end back (ZT-02).
    @Suite struct NativeMFDriveAbortTests {
        @Test func tapCancellingAnInFlightDriveStillAbortsAndReadsTheBodyBack() async throws {
            let transport = Transport(busyPolls: 1_000)
            let session = try await makeSession(transport)
            await transport.clear()
            let drive = Task { await session.mfDrive(towardNear: false, pulses: 400) }
            await transport.waitForReadinessPolls(2)
            // A tap pre-empts the dial by cancelling its task (`cancelManualFocusDrive`).
            drive.cancel()
            #expect(await drive.value == .refused(.deviceBusy))

            let operations = await transport.calls
            let cancel = try #require(operations.lastIndex(of: .afDriveCancel))
            #expect(operations[cancel...].contains(.deviceReady))
            try await session.changeAfArea(x: 3_024, y: 1_700)
            #expect(await transport.calls.last == .changeAfArea)
            session.close()
        }

        @Test func pollCeilingAbortReadsTheBodyBackBeforeHandingTheChannelOver() async throws {
            let transport = Transport(busyPolls: MFDriveChannelBudget.readinessPollLimit + 4)
            let session = try await makeSession(transport)
            await transport.clear()
            #expect(await session.mfDrive(towardNear: true, pulses: 80) == .refused(.deviceBusy))
            let operations = await transport.calls
            #expect(operations.last == .deviceReady)
            try await session.changeAfArea(x: 3_024, y: 1_700)
            session.close()
        }

        @Test func changeAfAreaReadsAnUnreadDriveBackInsteadOfFailingBusy() async throws {
            let transport = Transport(busyPolls: 0)
            let session = try await makeSession(transport)
            await transport.leaveDriveUnread()
            try await session.changeAfArea(x: 3_024, y: 1_700)
            let operations = await transport.calls
            #expect(operations == [.changeAfArea, .deviceReady, .changeAfArea])
            session.close()
        }

        private func makeSession(_ transport: Transport) async throws -> NativeCameraSession {
            try await NativeCameraSession.establish(
                transport: transport, host: "usb:mf-drive-abort", cameraName: "Z6III",
                requestPairing: false)
        }
    }

    private actor Transport: CameraTransport {
        nonisolated let kind: CameraTransportKind = .usb
        private let busyPolls: Int
        private(set) var calls: [PTPOperationCode] = []
        private var busyPollsRemaining = 0
        private var driveUnread = false
        private var readinessWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        init(busyPolls: Int) { self.busyPolls = busyPolls }

        func clear() { calls = [] }
        func leaveDriveUnread() {
            calls = []
            driveUnread = true
        }
        func waitForReadinessPolls(_ count: Int) async {
            if calls.filter({ $0 == .deviceReady }).count >= count { return }
            await withCheckedContinuation { readinessWaiter = (count, $0) }
        }

        func executeTransaction(
            operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
            dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?
        ) async throws -> PTPIPTransactionResult {
            // The production transports check cancellation after taking their gate.
            try Task.checkCancellation()
            calls.append(operationCode)
            var code = PTPResponseCode.ok
            switch operationCode {
            case .mfDrive:
                busyPollsRemaining = busyPolls
                driveUnread = true
            case .afDriveCancel:
                busyPollsRemaining = 0
            case .deviceReady:
                if busyPollsRemaining > 0 {
                    busyPollsRemaining -= 1
                    code = .deviceBusy
                } else {
                    driveUnread = false
                }
                if let waiter = readinessWaiter,
                    calls.filter({ $0 == .deviceReady }).count >= waiter.count
                {
                    readinessWaiter = nil
                    waiter.continuation.resume()
                }
            case .changeAfArea where driveUnread:
                code = .deviceBusy
            default:
                break
            }
            let payload =
                ByteCoding.uint16LE(code.rawValue) + ByteCoding.uint32LE(transactionID ?? 1)
            return PTPIPTransactionResult(
                operationResponse: try PTPOperationResponse(payloadBytes: payload),
                data: operationCode == .getDeviceInfo ? deviceInfo() : Data())
        }
        func executeTransaction(
            operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
            dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?,
            admission: NikonCommandAdmission
        ) async throws -> PTPIPTransactionResult {
            try admission.requireCurrent()
            return try await executeTransaction(
                operationCode: operationCode, transactionID: transactionID, parameters: parameters,
                dataPhase: dataPhase, dataOut: dataOut, deadline: deadline)
        }
        func nextEvent() async throws -> PTPEvent {
            throw NativeCameraSessionError.connectionClosed
        }
        nonisolated func close() {}
    }

    private func deviceInfo() -> Data {
        var bytes: [UInt8] = [100, 0, 10, 0, 0, 0, 100, 0]
        bytes += [0, 0, 0]  // Empty vendor extension string and functional mode.
        bytes += ByteCoding.uint32LE(0)
        for _ in 0..<4 { bytes += ByteCoding.uint32LE(0) }
        for value in ["Nikon", "Z6III", "1.0", "MF-DRIVE-ABORT"] {
            bytes.append(UInt8(value.utf16.count + 1))
            for unit in value.utf16 { bytes += ByteCoding.uint16LE(unit) }
            bytes += [0, 0]
        }
        return Data(bytes)
    }
#endif
