import Foundation
import OpenCineCore
import Testing

@testable import OpenCineNikon

/// Every dial a discovery pass made, by purpose, and the PTP bytes it would have sent.
final class FakeDialer: NikonDialer, @unchecked Sendable {
    // SAFETY: all state behind `lock`.
    private let lock = NSLock()
    private var log: [(host: String, purpose: NikonDialPurpose)] = []
    private var initCount = 0
    var presences: [String: NikonPresence] = [:]
    var alive: Set<String> = []
    var openControlPorts: Set<String> = []
    var cameras: [String: String] = [:]

    var dials: [(host: String, purpose: NikonDialPurpose)] { lock.withLock { log } }
    var controlDials: [String] { dials.filter { $0.purpose == .cameraControl }.map(\.host) }
    /// A PTP Init is the only call that sends PTP bytes.
    var ptpInits: Int { lock.withLock { initCount } }

    func presence(_ host: String) async -> NikonPresence? {
        lock.withLock { log.append((host, .presence)) }
        return presences[host]
    }

    func isAlive(_ host: String) async -> Bool {
        lock.withLock { log.append((host, .presence)) }
        return alive.contains(host)
    }

    func scanControlPort(_ hosts: [String]) async -> [String: HostProbeVerdict] {
        lock.withLock { log += hosts.map { ($0, .cameraControl) } }
        return Dictionary(uniqueKeysWithValues: hosts.map { ($0, openControlPorts.contains($0) ? .open : .timeout) })
    }

    func identify(_ host: String, guid: Data) async throws -> String? {
        lock.withLock {
            log.append((host, .cameraControl))
            initCount += 1
        }
        return cameras[host]
    }
}

struct FakeSources: NikonDiscoverySources {
    var bonjourCameras: [DiscoveredCamera] = []
    var usb: [DiscoveredCamera] = []
    func interfaces() -> [NikonLocalInterface] { [NikonLocalInterface(name: "en0", address: "192.168.1.42")] }
    func bonjour(timeout: Duration) async -> [DiscoveredCamera] { bonjourCameras }
    func usbCameras(start: Bool) async -> [DiscoveredCamera] { usb }
    func log(_ line: String) {}
}

/// SHELL-02 step 8: the Nikon passive-only rule, pinned. Kotlin mirror: `NikonDiscoveryTest`,
/// same method names.
@Suite struct NikonDiscoveryTests {
    let guid = Data(repeating: 1, count: 16)
    let bonjour = DiscoveredCamera(ip: "192.168.1.10", name: "Z_8", source: .bonjour)
    let usb = DiscoveredCamera(ip: "usb:1", name: "Z_6", source: .usb)

    func discovery(_ dialer: FakeDialer, bonjour: [DiscoveredCamera] = [], usb: Bool = true) -> NikonDiscovery {
        NikonDiscovery(
            dialer: dialer, sources: FakeSources(bonjourCameras: bonjour, usb: usb ? [self.usb] : []),
            now: { Date(timeIntervalSince1970: 0) })
    }

    @Test func passiveDiscoveryNeverDialsTheControlPort() async throws {
        let dialer = FakeDialer()
        dialer.presences = ["192.168.1.7": NikonPresence(deviceName: "Phone B", servedCamera: "192.168.1.20")]
        dialer.alive = ["192.168.1.30"]
        dialer.openControlPorts = ["192.168.1.30", "192.168.1.20"]
        dialer.cameras = ["192.168.1.30": "Z_f", "192.168.1.20": "Z_9"]
        let found = try await discovery(dialer, bonjour: [bonjour]).discover(
            .passive, guid: guid, priorityHosts: ["192.168.1.10", "192.168.1.30", "usb:1"])

        // Bonjour, USB, presence and liveness all ran, and not one dial reached a camera's control
        // service: zero camera-control dials, zero PTP bytes.
        #expect(dialer.controlDials.isEmpty && dialer.ptpInits == 0)
        #expect(dialer.dials.filter { $0.purpose == .presence }.count == 254)
        #expect(Set(found.map(\.ip)) == ["192.168.1.10", "usb:1", "192.168.1.30"])
        #expect(found.first { $0.ip == "192.168.1.30" }?.source == .liveness)
    }

    @Test func thePassiveDialerRefusesCameraControl() async {
        let dialer = FakeDialer()
        let passive = PassiveDialer(base: dialer)
        #expect(await passive.scanControlPort(["192.168.1.30"]).isEmpty)
        await #expect(throws: CancellationError.self) { try await passive.identify("192.168.1.30", guid: guid) }
        #expect(dialer.dials.isEmpty)
    }

    @Test func activeDiscoverySkipsShieldedHosts() async throws {
        let dialer = FakeDialer()
        dialer.presences = ["192.168.1.7": NikonPresence(deviceName: "Phone B", servedCamera: "192.168.1.20")]
        dialer.cameras = ["192.168.1.30": "Z_f", "192.168.1.20": "Z_9", "192.168.1.31": "Z_5"]
        let found = try await discovery(dialer).discover(
            .active, guid: guid, priorityHosts: ["192.168.1.20", "192.168.1.30", "192.168.1.31"],
            excludedHosts: { ["192.168.1.31"] })
        // The camera another device serves and the excluded one are never dialled.
        #expect(Set(dialer.controlDials) == ["192.168.1.30"] && dialer.ptpInits == 1)
        #expect(found.map(\.ip).contains("192.168.1.30") && !found.map(\.ip).contains("192.168.1.20"))
    }

    /// physical-C C9: the list's last sweep predated the phone that went live, so a saved connect
    /// asks with a fresh sweep, outside the list's rate window, and never dials the control port.
    @Test func currentHolderSweepsFreshAndNamesTheServingDevice() async throws {
        let dialer = FakeDialer()
        let nikon = discovery(dialer)
        _ = try await nikon.discover(.passive, guid: guid)
        dialer.presences = [
            "192.168.1.7": NikonPresence(deviceName: "Phone B", servedCamera: "192.168.1.20"),
            "192.168.1.8": NikonPresence(deviceName: "Phone C"),
        ]
        #expect(await nikon.currentHolder(of: "192.168.1.20") == "Phone B")
        #expect(await nikon.currentHolder(of: "192.168.1.30") == nil)
        let swept = dialer.dials.count
        #expect(await nikon.currentHolder(of: "usb:1") == nil)
        #expect(await nikon.currentHolder(of: "ap:NIKON_ZR") == nil)
        #expect(dialer.dials.count == swept, "a cable or a pending access point sweeps nothing")
        #expect(dialer.controlDials.isEmpty)
        #expect(!dialer.dials.contains { $0.host == "192.168.1.42" }, "this phone never asks itself")
    }

    @Test func theSweepIsMuteBeforeItIdentifies() async throws {
        let dialer = FakeDialer()
        dialer.openControlPorts = ["192.168.1.55"]
        dialer.cameras = ["192.168.1.55": "Z_r"]
        // A USB camera ends a pass before any sweep, so this phone has none.
        let found = try await discovery(dialer, usb: false).discover(.active, guid: guid)
        // Pass one dials the subnet without PTP bytes; only the host that answered gets an Init.
        #expect(dialer.ptpInits == 1)
        #expect(dialer.controlDials.count == 253 + 1, "the /24 minus this phone, then one Init")
        #expect(!dialer.controlDials.contains("192.168.1.42"))
        #expect(found.map(\.ip) == ["192.168.1.55"])
    }

    @Test func presenceSweepsAtMostEvery30Seconds() async throws {
        let dialer = FakeDialer()
        dialer.presences = ["192.168.1.7": NikonPresence(deviceName: "Phone B", servedCamera: "192.168.1.20")]
        let discovery = discovery(dialer)
        _ = try await discovery.discover(.passive, guid: guid)
        let afterFirst = dialer.dials.count
        _ = try await discovery.discover(.active, guid: guid, priorityHosts: ["192.168.1.20"])
        // No second sweep inside the window, and its shield still keeps the served camera safe.
        #expect(dialer.dials.filter { $0.purpose == .presence }.count == afterFirst)
        #expect(!dialer.controlDials.contains("192.168.1.20"))
    }
}
