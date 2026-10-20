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

        @Test func stabilizationDescribeRetainsNativeResponseMetadataAndScalarFacts() async throws {
            let transport = ObjectTransport(operations: [.getDevicePropDescEx])
            let session = try await establish(transport)
            defer { session.close() }
            let property = PTPPropertyCode.movieVibrationReduction
            let bytes = ByteCoding.uint32LE(property.rawValue) + [2, 0, 0, 0, 0, 2, 2, 0, 2, 99]
            await transport.describe(data: Data(bytes), response: 0x2001)
            await transport.clear()
            let actual = await session.observeCameraPropertyDescriptor(property, valueByteCount: 1)
            #expect(actual.outcome == .described)
            #expect(actual.descriptor?.writable == false)
            #expect(actual.descriptor?.form == .enumeration([[2], [99]]))
            #expect(actual.capability.offer == ["SPORT"])
            #expect(actual.capability.access == .readOnly)
            let call = try #require(await transport.calls.first)
            #expect(
                call.operation == .getDevicePropDescEx && call.parameters == [property.rawValue])
            #expect(call.phase == .dataIn && call.deadline == .seconds(15))
            for response: UInt16 in [0x2002, 0x2005, 0x200A, 0x2019] {
                await transport.describe(data: Data(), response: response)
                let refused = await session.observeCameraPropertyDescriptor(
                    property, valueByteCount: 1)
                #expect(refused.operation == .getDevicePropDescEx && refused.response == response)
                #expect(refused.outcome == .rejected)
                #expect(refused.capability.offer == nil)
                #expect(
                    refused.capability.support == .unknown)
            }
            await transport.describe(data: Data([0]), response: 0x2001)
            #expect(
                await session.observeCameraPropertyDescriptor(property, valueByteCount: 1).outcome
                    == .malformed)
            await transport.failDescribe()
            #expect(
                await session.observeCameraPropertyDescriptor(property, valueByteCount: 1).outcome
                    == .transportFailed)
        }

        @Test func cardSlotDescriptorsUseTheStandardDescribeForTheir16BitCodes() async throws {
            let transport = ObjectTransport(operations: [.getDevicePropDesc, .getDevicePropDescEx])
            let session = try await establish(transport)
            defer { session.close() }
            await transport.clear()
            _ = await session.readCardSlots()
            let describes = await transport.calls.filter {
                $0.operation == .getDevicePropDesc || $0.operation == .getDevicePropDescEx
            }
            #expect(describes.map(\.operation) == [.getDevicePropDesc, .getDevicePropDesc])
            #expect(
                describes.map(\.parameters) == [
                    [PTPPropertyCode.primarySlot.rawValue], [PTPPropertyCode.activeSlot.rawValue],
                ])
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
        private var describeData = Data()
        private var describeResponse: UInt16 = 0x2001
        private var describeFailed = false
        func describe(data: Data, response: UInt16) {
            describeData = data
            describeResponse = response
            describeFailed = false
        }
        func failDescribe() { describeFailed = true }
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
            if operationCode == .getDevicePropDescEx {
                if describeFailed { throw NativeCameraSessionError.connectionClosed }
                return PTPIPTransactionResult(
                    operationResponse: try PTPOperationResponse(
                        payloadBytes:
                            ByteCoding.uint16LE(describeResponse)
                            + ByteCoding.uint32LE(transactionID ?? 1)),
                    data: describeData)
            }
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
