import Darwin
import Foundation

/// Ask the camera DHCP server for 192.168.42.253 (option 50), then apply it.
/// Busybox udhcpd often NAKs addresses outside its pool; we log ACK/NAK/timeout.
enum LunaDHCP {
    struct Result: Sendable {
        var discoverPort: String
        var offer: String
        var ack: String
        var yiaddr: String
        var server: String
        var ioctl: Int32
        var held: Bool
    }

    static func requestScreenAddress(interface: String, mac: [UInt8], requested: String) -> Result {
        var result = Result(
            discoverPort: "none", offer: "none", ack: "none", yiaddr: "", server: "",
            ioctl: 1, held: false)
        guard mac.count == 6 else { return result }
        let xid = UInt32.random(in: 1...UInt32.max)
        guard let socket = DHCPSocket(interface: interface) else {
            result.discoverPort = "bind-failed"
            return result
        }
        result.discoverPort = "\(socket.port)"
        let discover = packet(
            xid: xid, mac: mac, type: 1, requested: requested, server: nil)
        _ = socket.send(discover, broadcast: true)
        _ = socket.send(discover, unicast: "192.168.42.1")
        var server: String?
        if let offer = socket.recv(timeout: 1.2, xid: xid) {
            result.offer = offer.typeName
            result.yiaddr = offer.yiaddr
            result.server = offer.server ?? ""
            server = offer.server ?? "192.168.42.1"
        }
        let request = packet(
            xid: xid, mac: mac, type: 3, requested: requested, server: server)
        _ = socket.send(request, broadcast: true)
        _ = socket.send(request, unicast: "192.168.42.1")
        if let ack = socket.recv(timeout: 1.2, xid: xid) {
            result.ack = ack.typeName
            if !ack.yiaddr.isEmpty { result.yiaddr = ack.yiaddr }
            if let s = ack.server { result.server = s }
        }
        socket.close()
        return result
    }

    private static func packet(
        xid: UInt32, mac: [UInt8], type: UInt8, requested: String, server: String?
    ) -> Data {
        var data = Data(count: 240)
        data[0] = 1
        data[1] = 1
        data[2] = 6
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: xid.bigEndian) { Data($0) })
        data[10] = 0x80
        data[11] = 0x00
        for i in 0..<6 { data[28 + i] = mac[i] }
        data[236] = 99
        data[237] = 130
        data[238] = 83
        data[239] = 99
        var options = Data()
        options.append(contentsOf: [53, 1, type])
        options.append(contentsOf: [61, 7, 1])
        options.append(contentsOf: mac)
        if let ip = ipv4(requested) {
            options.append(contentsOf: [50, 4])
            options.append(contentsOf: ip)
        }
        if let server, let ip = ipv4(server) {
            options.append(contentsOf: [54, 4])
            options.append(contentsOf: ip)
        }
        options.append(contentsOf: [12, 8] + Array("OpenInsta".utf8))
        options.append(contentsOf: [55, 3, 1, 3, 6])
        options.append(255)
        data.append(options)
        if data.count < 300 { data.append(Data(count: 300 - data.count)) }
        return data
    }

    private static func ipv4(_ text: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, text, &addr) == 1 else { return nil }
        let n = addr.s_addr
        return [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)]
    }
}

private final class DHCPSocket {
    let fd: Int32
    let port: UInt16

    init?(interface: String) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        let index = if_nametoindex(interface)
        if index != 0 {
            var idx = index
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        for candidate: UInt16 in [68, 0] {
            addr.sin_port = candidate.bigEndian
            let bound = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bound == 0 {
                var boundAddr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeMutablePointer(to: &boundAddr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getsockname(fd, $0, &len)
                    }
                }
                self.fd = fd
                self.port = UInt16(bigEndian: boundAddr.sin_port)
                return
            }
        }
        Darwin.close(fd)
        return nil
    }

    func send(_ data: Data, broadcast: Bool = false, unicast: String? = nil) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(67).bigEndian
        if broadcast {
            addr.sin_addr.s_addr = INADDR_BROADCAST.bigEndian
        } else if let unicast {
            inet_pton(AF_INET, unicast, &addr.sin_addr)
        } else {
            return false
        }
        let sent = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        fd, buffer.baseAddress, buffer.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == data.count
    }

    func recv(timeout: TimeInterval, xid: UInt32) -> DHCPParsed? {
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 1024)
            let count = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            guard count >= 240 else { continue }
            let data = Data(buffer.prefix(count))
            let gotXid = data.subdata(in: 4..<8).withUnsafeBytes {
                UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
            }
            guard gotXid == xid else { continue }
            return parse(data)
        }
        return nil
    }

    func close() { Darwin.close(fd) }

    private func parse(_ data: Data) -> DHCPParsed {
        let yi = data.subdata(in: 16..<20)
        let yiaddr = "\(yi[0]).\(yi[1]).\(yi[2]).\(yi[3])"
        var typeName = "unknown"
        var server: String?
        var offset = 240
        if data.count >= 240 { offset = 240 }
        while offset < data.count {
            let tag = data[offset]
            offset += 1
            if tag == 0 { continue }
            if tag == 255 { break }
            guard offset < data.count else { break }
            let len = Int(data[offset])
            offset += 1
            guard offset + len <= data.count else { break }
            let value = data.subdata(in: offset..<(offset + len))
            offset += len
            if tag == 53, let first = value.first {
                typeName = [1: "discover", 2: "offer", 3: "request", 5: "ack", 6: "nak"][first] ?? "type\(first)"
            }
            if tag == 54, value.count == 4 {
                server = "\(value[0]).\(value[1]).\(value[2]).\(value[3])"
            }
        }
        return DHCPParsed(typeName: typeName, yiaddr: yiaddr, server: server)
    }
}

private struct DHCPParsed {
    var typeName: String
    var yiaddr: String
    var server: String?
}
