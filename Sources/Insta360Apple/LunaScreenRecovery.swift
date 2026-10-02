import Darwin
import Foundation
import CKcp
import Insta360Protocol

// CKcp (ikcp), the same library as tools/luna_screen_live.py

/// Turns Color Recovery **off** using the same ScreenControl path as
/// `tools/luna_screen_live.py`: original KCP, kind-2 hello, prime from una, SET.
enum LunaScreenRecovery {
    static func disableColorRecovery(localAddress: String?, logPrefix: String) async throws {
        try await setRecovery(enabled: false, localAddress: localAddress, logPrefix: logPrefix)
    }

    static func setRecovery(enabled: Bool, localAddress: String?, logPrefix: String) async throws {
        guard let body = recoveryBody(enabled: enabled) else {
            throw CameraBackendError.unavailable(
                "Color Recovery \(enabled ? "on" : "off") body is not on this install.")
        }
        let (interface, holdsAddress, screenAddress) = await MainActor.run {
            (LunaWiFi.cameraInterface, LunaWiFi.holdsScreenAddress, LunaWiFi.screenAddress)
        }
        // The camera invites only the screen's address. From any other address it
        // sends no invitation, so there is no conversation to prime and the SET
        // would time out with nothing to explain it.
        // Tested on the phone 2026-09-17 with this guard removed: from a DHCP lease
        // the camera never opened a conversation. Refuse fast rather than burn
        // fifteen seconds discovering that.
        guard holdsAddress else {
            throw CameraBackendError.unavailable(
                "Color Recovery needs this device at \(screenAddress) on the camera network. "
                    + "Set that address for the camera Wi-Fi, then reconnect.")
        }
        try await Task.detached(priority: .userInitiated) {
            try ScreenControl(interface: interface, logPrefix: logPrefix).setRecovery(enabled: enabled, body: body)
        }.value
    }

    private static func recoveryBody(enabled: Bool) -> Data? {
        let urls = [
            Bundle.main.url(forResource: "RecoveryBodies", withExtension: "json"),
            Bundle.main.url(forResource: "recovery-set-bodies", withExtension: "json"),
        ].compactMap { $0 }
        for url in urls {
            guard let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any],
                let entry = json[enabled ? "on" : "off"] as? [String: Any],
                let hex = entry["body"] as? String
            else { continue }
            return hexData(hex)
        }
        return nil
    }

    private static func hexData(_ hex: String) -> Data? {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}

// MARK: - KCP (ikcp, same flags as tools/luna_screen_live.py)

private final class KCP: @unchecked Sendable {
    private var pointer: LunaKCP?
    private var outputBox: OutputBox?
    var conversation: UInt32
    var peerUna: UInt32 = 0

    private final class OutputBox {
        var send: ((Data) -> Void)?
        var callback: LunaKCPOutput?
    }

    init(conversation: UInt32, output: @escaping (Data) -> Void) throws {
        self.conversation = conversation
        let box = OutputBox()
        box.send = output
        let callback: LunaKCPOutput = { buf, len, _, user in
            guard let user, let buf, len > 0 else { return 0 }
            let box = Unmanaged<OutputBox>.fromOpaque(user).takeUnretainedValue()
            box.send?(Data(bytes: buf, count: Int(len)))
            return 0
        }
        box.callback = callback
        self.outputBox = box
        let user = Unmanaged.passUnretained(box).toOpaque()
        guard let pointer = luna_kcp_create(conversation, user) else {
            throw CameraBackendError.unavailable("KCP allocation failed.")
        }
        self.pointer = pointer
        luna_kcp_setoutput(pointer, callback)
        _ = luna_kcp_nodelay(pointer, 1, 20, 2, 1)
        _ = luna_kcp_wndsize(pointer, 256, 256)
        luna_kcp_update(pointer, KCP.now())
    }

    deinit { close() }

    func jumpSend(_ nxt: UInt32) {
        guard let pointer, nxt > 0 else { return }
        luna_kcp_jump_send(pointer, nxt)
    }

    func jumpRecv(_ nxt: UInt32) {
        guard let pointer, nxt > 0 else { return }
        luna_kcp_jump_recv(pointer, nxt)
    }

    func update() {
        guard let pointer else { return }
        luna_kcp_update(pointer, KCP.now())
    }

    func send(_ data: Data) throws {
        guard let pointer else {
            throw CameraBackendError.unavailable("No established screen conversation")
        }
        let result = data.withUnsafeBytes { buffer in
            luna_kcp_send(pointer, buffer.bindMemory(to: CChar.self).baseAddress, Int32(data.count))
        }
        guard result >= 0 else {
            throw CameraBackendError.unavailable("KCP send rejected")
        }
        update()
    }

    func input(_ data: Data) throws -> [Data] {
        guard let pointer else { return [] }
        let rc = data.withUnsafeBytes { buffer in
            luna_kcp_input(
                pointer, buffer.bindMemory(to: CChar.self).baseAddress, Int(data.count))
        }
        guard rc >= 0 else {
            throw CameraBackendError.unavailable("KCP input rejected")
        }
        var messages: [Data] = []
        while true {
            let size = luna_kcp_peeksize(pointer)
            if size < 0 { break }
            if size > 1024 * 1024 {
                throw CameraBackendError.unavailable("Oversized control response")
            }
            var buffer = [CChar](repeating: 0, count: max(Int(size), 1))
            let count = luna_kcp_recv(pointer, &buffer, size)
            if count < 0 { break }
            messages.append(Data(bytes: buffer, count: Int(count)))
        }
        return messages
    }

    func close() {
        if let pointer {
            luna_kcp_release(pointer)
            self.pointer = nil
        }
        outputBox = nil
    }

    private static func now() -> UInt32 {
        UInt32(truncatingIfNeeded: Int(ProcessInfo.processInfo.systemUptime * 1000))
    }
}

// MARK: - ScreenControl

private final class ScreenControl: @unchecked Sendable {
    private let logPrefix: String
    private let interface: String?
    private var control: UDPBox?
    private var media: UDPBox?
    private var kcp: KCP?
    private var mediaKCPs: [UInt32: KCP] = [:]
    private var identifier = UInt32.random(in: 1...0xFF_FFFF)
    private var proposal: (UInt32, UInt32)?
    private var ready = false
    private var lastKind2: TimeInterval = 0
    private var kind2Replies = 0
    private let tails: [UInt32] = [10, 8, 12, 11, 9, 6, 4, 3, 2, 1, 0, 14, 16]
    private let generation: UInt32 = 8

    init(interface: String?, logPrefix: String) {
        self.interface = interface
        self.logPrefix = logPrefix
    }

    func setRecovery(enabled: Bool, body: Data) throws {
        let control = try UDPBox.bind(port: 6021, interface: interface)
        self.control = control
        media = try? UDPBox.bind(port: 6023, interface: interface)
        defer {
            kcp?.close()
            mediaKCPs.values.forEach { $0.close() }
            control.close()
            media?.close()
        }

        let transaction = UInt32.random(in: 1...0xFF_FFFF)
        let conversation = UInt32.random(in: 1...0xFFFF_FFFE)
        proposal = (transaction, conversation)
        try sendKind2(flag: 0, transaction: transaction, conversation: conversation, tail: generation)

        let helloDeadline = Date().timeIntervalSinceReferenceDate + 8
        var lastSolicit = Date.distantPast.timeIntervalSinceReferenceDate
        while Date().timeIntervalSinceReferenceDate < helloDeadline, !ready {
            pump()
            if Date().timeIntervalSinceReferenceDate - lastSolicit >= 0.4, !ready {
                try sendKind2(
                    flag: 0, transaction: transaction, conversation: conversation,
                    tail: generation)
                lastSolicit = Date().timeIntervalSinceReferenceDate
            }
            drain(timeout: 0.05)
        }
        guard ready, kcp != nil else {
            throw CameraBackendError.unavailable(
                "The camera did not accept a screen-control conversation.")
        }

        let primed = try prime()
        NSLog("\(logPrefix) screen: conversation=0x\(String(kcp?.conversation ?? 0, radix: 16)) primed=\(primed) media=\(media != nil)")
        guard primed > 0 else {
            throw CameraBackendError.unavailable(
                "Camera sequence unknown; refusing to send Color Recovery blind.")
        }

        // Acceptance is intermittent: the camera sometimes ignores the first write
        // while its own session is still settling. Observed failing three times and
        // succeeding on the fourth with no other difference, so retry rather than
        // report a failure the operator can do nothing about.
        for attempt in 1...3 {
            if try sendRecoveryBody(body) { return }
            NSLog("\(logPrefix) screen: write not accepted, attempt \(attempt) of 3")
            _ = try? prime()
        }
        throw CameraBackendError.unavailable(
            "The camera did not accept the Color Recovery command after three attempts.")
    }

    private func sendRecoveryBody(_ body: Data) throws -> Bool {
        identifier = (identifier &+ 1) & 0x7FFF_FFFF
        let payload = ScreenWire.rpc(service: 1, method: 2, identifier: identifier, body: body)
        let envelope = try ScreenWire.Envelope(
            kind: 0, source: 0x0814, destination: 0x0405, payload: payload
        ).encode()
        let before = kcp?.peerUna ?? 0
        let sentAt = Date().timeIntervalSinceReferenceDate
        try kcp?.send(envelope)
        pump()
        // The body is about 2.6 KB and fragments across several KCP segments, so
        // acceptance needs a retransmit window, not a single round trip. The Mac
        // client allows four seconds; 1.5 was too tight and failed on device.
        let wait = Date().timeIntervalSinceReferenceDate + 6
        while Date().timeIntervalSinceReferenceDate < wait {
            pump()
            drain(timeout: 0.02)
            if (kcp?.peerUna ?? 0) > before { break }
        }
        let after = kcp?.peerUna ?? 0
        let ackMs = Int((Date().timeIntervalSinceReferenceDate - sentAt) * 1000)
        NSLog("\(logPrefix) screen: body=\(body.count) before=\(before) after=\(after) ack_ms=\(ackMs)")
        return after > before
    }

    private func prime() throws -> UInt32 {
        guard let kcp else {
            throw CameraBackendError.unavailable("No established screen conversation")
        }
        if kcp.peerUna > 0 {
            kcp.jumpSend(kcp.peerUna)
            return kcp.peerUna
        }
        identifier = (identifier &+ 1) & 0x7FFF_FFFF
        let payload = ScreenWire.rpc(
            service: 2, method: 1, identifier: identifier, body: Data([2, 0, 0, 0]))
        let envelope = try ScreenWire.Envelope(
            kind: 0, source: 0x0BFB, destination: 0x07FC, payload: payload
        ).encode()
        try kcp.send(envelope)
        let deadline = Date().timeIntervalSinceReferenceDate + 4
        while Date().timeIntervalSinceReferenceDate < deadline {
            pump()
            drain(timeout: 0.05)
            if kcp.peerUna > 0 {
                kcp.jumpSend(kcp.peerUna)
                return kcp.peerUna
            }
        }
        return 0
    }

    private func adopt(_ conversation: UInt32) {
        if let kcp, kcp.conversation != conversation { return }
        if kcp == nil {
            let logPrefix = logPrefix
            kcp = try? KCP(conversation: conversation) { [weak self] data in
                // Temporary wire tracing: which KCP segments actually leave the device.
                if data.count >= 24 {
                    let b = [UInt8](data)
                    let cmd = b[4]
                    func le32(_ i: Int) -> UInt32 {
                        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
                    }
                    NSLog("\(logPrefix) wire: TX cmd=\(cmd) sn=\(le32(12)) una=\(le32(16)) len=\(le32(20))")
                }
                do {
                    try self?.control?.send(data, host: "192.168.42.1", port: 6000)
                } catch {
                    NSLog("\(logPrefix) wire: TX FAILED \(error)")
                }
            }
            kcp?.update()
            ready = kcp != nil
        }
    }

    private func pump() {
        kcp?.update()
        mediaKCPs.values.forEach { $0.update() }
    }

    private func drain(timeout: TimeInterval) {
        if let packet = try? control?.recv(timeout: timeout) {
            handleControl(packet)
        }
        if let packet = try? media?.recv(timeout: 0) {
            handleMedia(packet)
        }
    }

    private func handleControl(_ data: Data) {
        if data.count == 25, data.first == 2,
            let envelope = try? ScreenWire.decodeEnvelope(data),
            let hello = try? ScreenWire.decodeKind2(envelope)
        {
            lastKind2 = Date().timeIntervalSinceReferenceDate
            if hello.flag == 0 {
                let tail = tails[kind2Replies % tails.count]
                kind2Replies += 1
                try? sendKind2(
                    flag: 1, transaction: hello.transaction, conversation: hello.conversation,
                    tail: tail)
                adopt(hello.conversation)
            } else if hello.flag == 1, let proposal,
                hello.transaction == proposal.0
            {
                adopt(hello.conversation == 0 ? proposal.1 : hello.conversation)
            }
            return
        }
        guard let kcp else { return }
        if let segments = try? ScreenWire.decodeKCP(data) {
            for segment in segments {
                if segment.una > kcp.peerUna { kcp.peerUna = segment.una }
                if segment.command == ScreenWire.kcpPush {
                    kcp.jumpRecv(segment.sequence)
                }
            }
            if kcp.peerUna > 0 { kcp.jumpSend(kcp.peerUna) }
        }
        _ = try? kcp.input(data)
    }

    private func handleMedia(_ data: Data) {
        if data.count == 25, data.first == 2,
            let envelope = try? ScreenWire.decodeEnvelope(data),
            let hello = try? ScreenWire.decodeKind2(envelope), hello.flag == 0
        {
            let tail = tails[kind2Replies % tails.count]
            kind2Replies += 1
            if let reply = try? ScreenWire.kind2Hello(
                flag: 1, transaction: hello.transaction, conversation: hello.conversation,
                tail: tail)
            {
                try? media?.send(reply, host: "192.168.42.1", port: 6002)
            }
            if mediaKCPs[hello.conversation] == nil {
                mediaKCPs[hello.conversation] = try? KCP(conversation: hello.conversation) {
                    [weak self] payload in
                    try? self?.media?.send(payload, host: "192.168.42.1", port: 6002)
                }
                mediaKCPs[hello.conversation]?.update()
            }
            return
        }
        if let conversation = data.count >= 4
            ? data.prefix(4).withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self).littleEndian })
            : nil
        {
            _ = try? mediaKCPs[conversation]?.input(data)
        }
    }

    private func sendKind2(flag: UInt8, transaction: UInt32, conversation: UInt32, tail: UInt32)
        throws
    {
        try control?.send(
            ScreenWire.kind2Hello(
                flag: flag, transaction: transaction, conversation: conversation, tail: tail),
            host: "192.168.42.1", port: 6000)
    }
}

private final class UDPBox: @unchecked Sendable {
    private let fd: Int32

    static func bind(port: UInt16, interface: String?) throws -> UDPBox {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw CameraBackendError.unavailable("Could not open a screen UDP socket.")
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        if let interface {
            let index = if_nametoindex(interface)
            if index != 0 {
                var idx = index
                setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
            }
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            throw CameraBackendError.unavailable("Could not bind screen UDP port \(port).")
        }
        return UDPBox(fd: fd)
    }

    private init(fd: Int32) { self.fd = fd }
    func close() { Darwin.close(fd) }

    func send(_ data: Data, host: String, port: UInt16) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let sent = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        fd, buffer.baseAddress, buffer.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else {
            throw CameraBackendError.unavailable("Screen UDP send failed.")
        }
    }

    func recv(timeout: TimeInterval) throws -> Data? {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 2048)
        let count = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
        if count <= 0 { return nil }
        return Data(buffer.prefix(count))
    }
}
