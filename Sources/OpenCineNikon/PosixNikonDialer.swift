#if canImport(Darwin) && canImport(os)

    import Darwin
    import Foundation

    /// The phone's dialer over POSIX sockets and `PTPIPTransport` (moved from OpenZCine's
    /// discovery). Presence and liveness use raw non-blocking sockets so a deadline closes the
    /// flow at once (an abandoned connect otherwise retransmits SYNs for ~75 s); the app decodes
    /// its own presence line.
    public struct PosixNikonDialer: NikonDialer {
        public var presencePort: UInt16
        public var decodePresence: @Sendable (Data) -> NikonPresence?

        public init(presencePort: UInt16 = 15741, decodePresence: @escaping @Sendable (Data) -> NikonPresence?) {
            self.presencePort = presencePort
            self.decodePresence = decodePresence
        }

        public func presence(_ host: String) async -> NikonPresence? {
            let line = await Self.onProbeQueue { Self.rawProbe(host: host, port: presencePort, timeoutMilliseconds: 500) }
                .line
            guard let line, var presence = decodePresence(line) else { return nil }
            presence.line = line
            return presence
        }

        /// HW-measured: an idle body answers a dial in about 1.0-1.2 s (Wi-Fi power save), hence
        /// the longer deadline than the sweep's.
        public func isAlive(_ host: String) async -> Bool {
            await Self.onProbeQueue { Self.rawProbe(host: host, port: presencePort, timeoutMilliseconds: 1_500) }
                .reachedHost
        }

        public func scanControlPort(_ hosts: [String]) async -> [String: HostProbeVerdict] {
            await PTPIPTransport.scanPorts(hosts: hosts)
        }

        public func identify(_ host: String, guid: Data) async throws -> String? {
            try await PTPIPTransport.probeCameraName(host: host, guid: guid, timeoutMilliseconds: 1_800)
        }

        /// Probes block a worker in `poll`, so they run on their own concurrent queue, never the
        /// cooperative pool.
        private static let queue = DispatchQueue(label: "com.opencapture.opencine.nikon.presence", attributes: .concurrent)

        private static func onProbeQueue(
            _ work: @escaping @Sendable () -> (reachedHost: Bool, line: Data?)
        ) async -> (reachedHost: Bool, line: Data?) {
            await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: work()) } }
        }

        /// Bounded connect plus one read. `reachedHost`: the connect succeeded or was refused (a
        /// kernel RST needs a live host); `line`: the answer when the port was served.
        private static func rawProbe(host: String, port: UInt16, timeoutMilliseconds: Int32) -> (reachedHost: Bool, line: Data?) {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return (false, nil) }
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return (false, nil) }
            defer { close(fd) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
            var noSigpipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { return (errno == ECONNREFUSED, nil) }
                var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&writable, 1, timeoutMilliseconds) == 1 else { return (false, nil) }
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                guard socketError == 0 else { return (socketError == ECONNREFUSED, nil) }
            }
            var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&readable, 1, timeoutMilliseconds) == 1 else { return (true, nil) }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { return (true, nil) }
            return (true, Data(buffer.prefix(received)))
        }
    }
#endif
