#if canImport(Darwin) && canImport(os)
    import Darwin
    import Foundation
    import Testing

    @testable import OpenCineNikon

    /// Owner hardware report 2026-10-29 (ZR over Wi-Fi): open a clip so the player streams it,
    /// leave the player before the clip is cached, then Share it. Leaving cancels the player's
    /// stream while its partial-object read is on the wire. That cancellation must not cost the
    /// camera session: the next request on the same transport gets its own answer.
    @Suite(.timeLimit(.minutes(1))) struct PTPIPCancelledTransactionTests {
        private static let clip = Data((0..<8).map { UInt8($0) })

        private func read(_ transport: PTPIPTransport, offset: UInt32) async throws
            -> PTPIPTransactionResult
        {
            try await transport.executeTransaction(
                operationCode: .getPartialObject, transactionID: nil,
                parameters: [PTPIPLoopbackCamera.clipHandle, offset, 4], dataPhase: .dataIn,
                dataOut: nil, deadline: nil)
        }

        @Test func cancellingAReadOnTheWireKeepsTheCameraSession() async throws {
            let camera = try PTPIPLoopbackCamera(clip: Self.clip, holdFirstRead: true)
            defer { camera.stop() }
            let transport = try await PTPIPTransport.connectOnce(
                host: "127.0.0.1", port: camera.port, guid: Data(repeating: 0x11, count: 16),
                friendlyName: "SIMULATED")
            defer { transport.close() }

            // The player's read reaches the camera, which holds its answer.
            let player = Task { try await read(transport, offset: 0) }
            await camera.requests.wait(1)
            // The operator leaves the player while that read is on the wire.
            player.cancel()
            camera.releaseHeldRead()
            _ = await player.result

            // Share resumes the clip on the same transport.
            let share = try await read(transport, offset: 4)
            #expect(share.operationResponse.responseCode == .ok)
            #expect(share.data == Data([4, 5, 6, 7]), "Share gets its own bytes")
            #expect(!camera.commandChannelClosed, "The camera session is still open")
        }

        /// A transfer that loses the camera reads as the camera stopping; a refusal does not.
        @Test func aDeadLinkIsALinkFailureAndARefusalIsNot() {
            for error in [
                NativeCameraSessionError.connectionClosed, .timeout("command receive"),
                .connectionFailed("command receive failed"), .invalidPacketLength(3),
            ] {
                #expect(NativeCameraSessionError.isLinkFailure(error))
            }
            #expect(
                !NativeCameraSessionError.isLinkFailure(
                    NativeCameraSessionError.operationRejected(.getPartialObject, .deviceBusy)))
            #expect(!NativeCameraSessionError.isLinkFailure(CancellationError()))
            #expect(
                !NativeCameraSessionError.isLinkFailure(
                    PTPObjectTransferError.unresolvedObjectSize(reportedBytes: 0)))
        }
    }

    /// Counts events from the camera's threads and lets a test await a count without sleeping.
    final class PTPIPLoopbackSignal: @unchecked Sendable {
        // SAFETY: every access holds `lock`.
        private let lock = NSLock()
        private var count = 0
        private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        func bump() {
            lock.lock()
            count += 1
            let ready = waiters.filter { $0.count <= count }
            waiters.removeAll { $0.count <= count }
            lock.unlock()
            for waiter in ready { waiter.continuation.resume() }
        }

        func wait(_ target: Int) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if count >= target {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append((target, continuation))
                lock.unlock()
            }
        }
    }

    /// A SIMULATED PTP-IP camera on an ephemeral loopback port: the Init handshake and
    /// `GetPartialObject` over one clip. The first read can be held until the test releases it.
    final class PTPIPLoopbackCamera: @unchecked Sendable {
        static let clipHandle: UInt32 = 7
        let port: UInt16
        let requests = PTPIPLoopbackSignal()
        private let clip: Data
        private let listener: Int32
        private let heldRead = DispatchSemaphore(value: 0)
        // SAFETY: the fields below are guarded by `lock`.
        private let lock = NSLock()
        private var holdNextRead: Bool
        private var connections: [Int32] = []
        private var commandConnection: Int32 = -1
        private var commandClosed = false

        var commandChannelClosed: Bool { lock.withLock { commandClosed } }

        init(clip: Data, holdFirstRead: Bool) throws {
            self.clip = clip
            holdNextRead = holdFirstRead
            let descriptor = socket(AF_INET, SOCK_STREAM, Int32(IPPROTO_TCP))
            guard descriptor >= 0 else { throw LoopbackError.socket }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, listen(descriptor, 4) == 0 else {
                close(descriptor)
                throw LoopbackError.socket
            }
            var actual = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &actual) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            port = UInt16(bigEndian: actual.sin_port)
            listener = descriptor
            Thread.detachNewThread { [self] in acceptLoop() }
        }

        func releaseHeldRead() { heldRead.signal() }

        func stop() {
            heldRead.signal()
            Darwin.shutdown(listener, SHUT_RDWR)
            let open = lock.withLock { connections }
            for connection in open { Darwin.shutdown(connection, SHUT_RDWR) }
        }

        private func acceptLoop() {
            defer { close(listener) }
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                var noSigPipe: Int32 = 1
                setsockopt(
                    connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                    socklen_t(MemoryLayout<Int32>.size))
                lock.withLock { connections.append(connection) }
                Thread.detachNewThread { [self] in serve(connection) }
            }
        }

        private func serve(_ connection: Int32) {
            defer {
                lock.withLock {
                    if connection == commandConnection { commandClosed = true }
                }
                close(connection)
            }
            while let packet = try? readPacket(connection) {
                switch packet.type {
                case .initCommandRequest:
                    lock.withLock { commandConnection = connection }
                    var payload = ByteCoding.uint32LE(1)
                    payload += [UInt8](repeating: 0xAB, count: 16)
                    payload += PTPIPFriendlyName.encode("SIMULATED")
                    send(connection, PTPIPPacket(type: .initCommandAck, payload: Data(payload)))
                case .initEventRequest:
                    send(connection, PTPIPPacket(type: .initEventAck, payload: Data()))
                case .operationRequest:
                    answer(connection, Array(packet.payload))
                default:
                    return
                }
            }
        }

        private func answer(_ connection: Int32, _ request: [UInt8]) {
            let operation = ByteCoding.readUInt16LE(request, at: 4)
            let transactionID = ByteCoding.readUInt32LE(request, at: 6)
            let parameters = stride(from: 10, to: request.count, by: 4).map {
                ByteCoding.readUInt32LE(request, at: $0)
            }
            requests.bump()
            guard operation == PTPOperationCode.getPartialObject.rawValue,
                parameters.count >= 3, parameters[0] == Self.clipHandle
            else {
                respond(connection, code: 0x2005, transactionID)
                return
            }
            let hold = lock.withLock {
                defer { holdNextRead = false }
                return holdNextRead
            }
            if hold { heldRead.wait() }
            let start = min(Int(parameters[1]), clip.count)
            let end = min(start + Int(parameters[2]), clip.count)
            let data = clip.subdata(in: start..<end)
            send(
                connection,
                PTPIPPacket(
                    type: .startData,
                    payload: Data(
                        PTPDataPayloads.startData(
                            transactionID: transactionID, totalLength: UInt64(data.count)))))
            send(
                connection,
                PTPIPPacket(
                    type: .endData,
                    payload: Data(
                        PTPDataPayloads.endData(transactionID: transactionID, data: data))))
            respond(connection, code: PTPResponseCode.ok.rawValue, transactionID)
        }

        private func respond(_ connection: Int32, code: UInt16, _ transactionID: UInt32) {
            let payload = ByteCoding.uint16LE(code) + ByteCoding.uint32LE(transactionID)
            send(connection, PTPIPPacket(type: .operationResponse, payload: Data(payload)))
        }

        private func send(_ connection: Int32, _ packet: PTPIPPacket) {
            let bytes = packet.serializedBytes
            var offset = 0
            while offset < bytes.count {
                let sent = bytes[offset...].withUnsafeBytes {
                    Darwin.send(connection, $0.baseAddress, $0.count, 0)
                }
                guard sent > 0 else { return }
                offset += sent
            }
        }

        private func readPacket(_ connection: Int32) throws -> PTPIPPacket {
            let header = try readExact(connection, 8)
            let length = Int(ByteCoding.readUInt32LE(header, at: 0))
            guard length >= 8, length <= 1 << 20 else { throw LoopbackError.frame }
            return try PTPIPPacket(serializedBytes: header + readExact(connection, length - 8))
        }

        private func readExact(_ connection: Int32, _ count: Int) throws -> [UInt8] {
            var collected: [UInt8] = []
            while collected.count < count {
                var chunk = [UInt8](repeating: 0, count: count - collected.count)
                let received = chunk.withUnsafeMutableBytes {
                    recv(connection, $0.baseAddress, $0.count, 0)
                }
                guard received > 0 else { throw LoopbackError.closed }
                collected += chunk.prefix(received)
            }
            return collected
        }

        private enum LoopbackError: Error { case socket, frame, closed }
    }
#endif
