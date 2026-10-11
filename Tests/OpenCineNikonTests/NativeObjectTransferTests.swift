#if canImport(Darwin) && canImport(os)
    import Foundation
    import Testing
    @testable import OpenCineNikon

    /// SIMULATED: actual native-session executor over one scripted serialized transport.
    @MainActor @Suite struct NativeObjectTransferTests {
        @Test func ordinarySizeNeedsNoAdditionalTransaction() async throws {
            let transport = ObjectTransport(operations: [])
            let session = try await establish(transport)
            defer { session.close() }
            await transport.clear()
            #expect(try await session.resolvedObjectSize(handle: 9, reportedSize: 100) == 100)
            #expect(await transport.calls.isEmpty)
        }

        @Test func advertisedSentinelResolutionReturnsTrueUInt64Size() async throws {
            let total = UInt64(UInt32.max) + 901
            let transport = ObjectTransport(operations: [.getObjectSize], size: total)
            let session = try await establish(transport)
            defer { session.close() }
            await transport.clear()
            #expect(
                try await session.resolvedObjectSize(handle: 9, reportedSize: UInt64(UInt32.max))
                    == total)
            let call = try #require(await transport.calls.first)
            #expect(call.operation == .getObjectSize && call.parameters == [9])
            #expect(call.phase == .dataIn && call.deadline == .seconds(15))
        }

        @Test func absentSizeCapabilitySendsNoQuery() async throws {
            for operations: [PTPOperationCode] in [[], [.getPartialObject]] {
                let transport = ObjectTransport(operations: operations)
                let session = try await establish(transport)
                defer { session.close() }
                await transport.clear()
                await #expect(throws: PTPObjectTransferError.objectSizeResolutionUnsupported) {
                    try await session.resolvedObjectSize(
                        handle: 9, reportedSize: UInt64(UInt32.max))
                }
                #expect(await transport.calls.isEmpty)
            }
        }

        @Test func sizeQueryRejectsUnknownTruncatedAndRefusedReplies() async throws {
            for size in [UInt64(0), UInt64(UInt32.max)] {
                let transport = ObjectTransport(operations: [.getObjectSize], size: size)
                let session = try await establish(transport)
                defer { session.close() }
                await #expect(
                    throws: PTPObjectTransferError.unresolvedObjectSize(reportedBytes: size)
                ) {
                    try await session.resolvedObjectSize(
                        handle: 9, reportedSize: UInt64(UInt32.max))
                }
            }
            let truncated = ObjectTransport(operations: [.getObjectSize], sizePayload: Data([1]))
            let session = try await establish(truncated)
            defer { session.close() }
            await #expect(throws: PTPObjectTransferError.truncatedObjectSize(actualLength: 1)) {
                try await session.resolvedObjectSize(handle: 9, reportedSize: UInt64(UInt32.max))
            }
            await truncated.rejectSize()
            await #expect(throws: NativeCameraSessionError.self) {
                try await session.resolvedObjectSize(handle: 9, reportedSize: UInt64(UInt32.max))
            }
        }

        @Test func realExecutorPreservesStandardAndExtendedBoundaryWords() async throws {
            let transport = ObjectTransport(operations: [.getPartialObject, .getPartialObjectEx])
            let session = try await establish(transport)
            defer { session.close() }
            await transport.clear()
            let standard = try PTPPartialObjectRequest(
                objectHandle: 9, offset: UInt64(UInt32.max) - 1, maximumBytes: 1,
                totalBytes: UInt64(UInt32.max), supportsExtendedReads: false)
            let extended = try PTPPartialObjectRequest(
                objectHandle: 9, offset: UInt64(UInt32.max) + 10, maximumBytes: 4,
                totalBytes: UInt64(UInt32.max) + 14, supportsExtendedReads: true)
            _ = try await session.getPartialObject(standard)
            _ = try await session.getPartialObject(extended)
            let calls = await transport.calls
            #expect(calls.map(\.operation) == [.getPartialObject, .getPartialObjectEx])
            #expect(calls[0].parameters == [9, UInt32.max - 1, 1])
            #expect(calls[1].parameters == [9, 9, 1, 4, 0])
            #expect(calls.allSatisfy { $0.phase == .dataIn && $0.deadline == .seconds(15) })
        }

        @Test func manuallyPlannedExtendedRequestStillRequiresActualCapability() async throws {
            let transport = ObjectTransport(operations: [.getPartialObject])
            let session = try await establish(transport)
            defer { session.close() }
            await transport.clear()
            let request = try PTPPartialObjectRequest(
                objectHandle: 9, offset: UInt64(UInt32.max) + 1, maximumBytes: 4,
                totalBytes: UInt64(UInt32.max) + 5, supportsExtendedReads: true)
            await #expect(
                throws: PTPObjectTransferError.extendedReadUnsupported(
                    totalBytes: request.endOffset)
            ) {
                try await session.getPartialObject(request)
            }
            #expect(await transport.calls.isEmpty)
        }

        private func establish(_ transport: ObjectTransport) async throws -> NativeCameraSession {
            try await NativeCameraSession.establish(
                transport: transport, host: "usb:SIMULATED-transfer", cameraName: "SIMULATED",
                requestPairing: false)
        }
    }

    private actor ObjectTransport: CameraTransport {
        struct Call: Sendable {
            let operation: PTPOperationCode
            let parameters: [UInt32]
            let phase: PTPDataPhase
            let deadline: Duration?
        }
        nonisolated let kind: CameraTransportKind = .usb
        let operations: [PTPOperationCode]
        let sizePayload: Data
        private var sizeRejected = false
        private(set) var calls: [Call] = []
        init(operations: [PTPOperationCode], size: UInt64 = 100, sizePayload: Data? = nil) {
            self.operations = operations
            self.sizePayload = sizePayload ?? Data(ByteCoding.uint64LE(size))
        }
        func clear() { calls = [] }
        func rejectSize() { sizeRejected = true }
        func executeTransaction(
            operationCode: PTPOperationCode, transactionID: UInt32?, parameters: [UInt32],
            dataPhase: PTPDataPhase, dataOut: Data?, deadline: Duration?
        ) async throws -> PTPIPTransactionResult {
            calls.append(
                .init(
                    operation: operationCode, parameters: parameters, phase: dataPhase,
                    deadline: deadline))
            let response: PTPResponseCode =
                operationCode == .getObjectSize && sizeRejected ? .unknown : .ok
            let reply =
                ByteCoding.uint16LE(response.rawValue) + ByteCoding.uint32LE(transactionID ?? 1)
            let data =
                operationCode == .getDeviceInfo
                ? deviceInfo()
                : operationCode == .getObjectSize ? sizePayload : Data([1])
            return PTPIPTransactionResult(
                operationResponse: try PTPOperationResponse(payloadBytes: reply), data: data)
        }
        func nextEvent() async throws -> PTPEvent {
            throw NativeCameraSessionError.connectionClosed
        }
        nonisolated func close() {}
        private func deviceInfo() -> Data {
            var bytes: [UInt8] = [100, 0, 10, 0, 0, 0, 100, 0, 0, 0, 0]
            bytes += ByteCoding.uint32LE(UInt32(operations.count))
            for operation in operations { bytes += ByteCoding.uint16LE(operation.rawValue) }
            for _ in 0..<4 { bytes += ByteCoding.uint32LE(0) }
            for value in ["SIMULATED", "SIMULATED", "1.0", "SIMULATED-transfer"] {
                bytes.append(UInt8(value.utf16.count + 1))
                for unit in value.utf16 { bytes += ByteCoding.uint16LE(unit) }
                bytes += [0, 0]
            }
            return Data(bytes)
        }
    }
#endif
