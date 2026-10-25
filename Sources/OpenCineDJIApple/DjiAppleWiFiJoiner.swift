#if os(iOS)
import Darwin
import Foundation
import Network
import NetworkExtension
import OpenCineCore
import OpenCineDJI

/// Joins the camera's SoftAP with the credentials read over BLE. Requires the
/// `com.apple.developer.networking.HotspotConfiguration` entitlement. The camera is an
/// internet-less AP at 192.168.2.1; iOS keeps cellular as the default route, so sockets that need
/// the camera must pin themselves to Wi-Fi (see DatalinkDriver's NWParameters).
///
/// `apply` success is not "associated with an address". First join is prompt + associate +
/// DHCP; second connect is already on the AP (`alreadyAssociated`) and `192.168.2.x` is there.
@MainActor
public enum DjiAppleWiFiJoiner {
    public enum JoinError: LocalizedError {
        case failed(String)
        case pathNotReady
        case timedOut
        case stillOnOtherBody(String)
        /// Personal Hotspot is hosting, so iOS never takes a camera AP address.
        case personalHotspot
        public var errorDescription: String? {
            switch self {
            case .failed(let s):
                "couldn't join camera Wi-Fi (\(s)). \(CameraSoftAPSwitch.frequencyHint)"
            case .timedOut:
                "Camera Wi-Fi did not finish joining. Try connecting again."
            case .pathNotReady:
                "camera Wi-Fi joined but 192.168.2.x never appeared. \(CameraSoftAPSwitch.frequencyHint)"
            case .stillOnOtherBody(let ssid):
                "couldn't switch from \(ssid) \u{2014} tap Connect again"
            case .personalHotspot: "Turn off Personal Hotspot, then try again. While it is on, this iPhone cannot join the camera Wi-Fi."
            }
        }

        /// A wrong or regenerated passphrase also ends as `pathNotReady` (iOS applies
        /// the config, then silently fails to join), so only a join blocked by Personal
        /// Hotspot is known to leave the saved credentials valid.
        public static func rejectsCredentials(_ error: Error) -> Bool {
            if case JoinError.personalHotspot = error { return false }
            return true
        }
    }

    /// Journal (caller-owned), not only os_log: the diagnostic report
    /// showed `phase: joiningWifi` with no line about why (#235).

    /// Leave the other Osmo SoftAP and join `ssid`. Pocket and Nano share
    /// `192.168.2.1`, so a leftover camera DHCP address is not a stop - apply
    /// the target hotspot and let iOS switch. Do not send the operator to Settings.
    public static func joinCameraAP(
        ssid: String,
        passphrase: String,
        wpa3: Bool,
        knownOtherSSIDs: [String],
        persist: Bool = false,
        host: DjiAppleTransportHost = .init(),
        isCurrent: @escaping CameraNetworkIsCurrent = { true }
    ) async throws {
        guard let hotspot = host.hotspot else {
            // Compatibility for clients without a host-owned hotspot owner: the original calls.
            try await joinCameraAP(ssid: ssid, passphrase: passphrase, wpa3: wpa3,
                knownOtherSSIDs: knownOtherSSIDs, persist: persist, host: host, mutations: .legacy(host))
            return
        }
        try await hotspot.withAttempt(isCurrent) { operations in
            try await joinCameraAP(ssid: ssid, passphrase: passphrase, wpa3: wpa3,
                knownOtherSSIDs: knownOtherSSIDs, persist: persist, host: host,
                mutations: .shared(hotspot, operations, host: host))
        }
    }

    /// The hotspot actions of one join workflow: the host's retained owner (serialized behind any
    /// still pending native apply) or the original direct calls.
    @MainActor struct Mutations {
        var apply: (_ ssid: String, _ passphrase: String, _ wpa3: Bool, _ persist: Bool,
            _ timeout: Duration) async throws -> Void
        var remove: (String) -> Void
        var currentSSID: () async -> String?
        var configuredSSIDs: () async -> [String]

        static func legacy(_ host: DjiAppleTransportHost) -> Self {
            .init(apply: { ssid, passphrase, wpa3, persist, timeout in
                try await join(ssid: ssid, passphrase: passphrase, wpa3: wpa3, persist: persist,
                    timeout: timeout, host: host)
            }, remove: { leave(ssid: $0) }, currentSSID: { await DjiAppleWiFiJoiner.currentSSID() },
                configuredSSIDs: { await DjiAppleWiFiJoiner.configuredSSIDs() })
        }

        static func shared(_ hotspot: CameraHotspotHost, _ operations: CameraHotspotOperations,
            host: DjiAppleTransportHost) -> Self {
            .init(apply: { ssid, passphrase, _, persist, timeout in
                do {
                    // Join-once drops the hotspot when the app leaves the foreground; saved
                    // cameras need the config to survive Control Center / background.
                    try await operations.apply(.init(selection: .ssid(ssid),
                        security: .personal(passphrase: passphrase), joinOnce: !persist, timeout: timeout))
                    try applyOutcome(nil, ssid: ssid, persist: persist, host: host).get()
                } catch is CancellationError {
                    throw CancellationError()
                } catch CameraHotspotError.timedOut {
                    throw JoinError.timedOut
                } catch let refusal as CameraHotspotJoinRefusal {
                    host.journal("wifi: join refused \(refusal.diagnosticsCode)")
                    throw refusal
                } catch {
                    try applyOutcome(error as NSError, ssid: ssid, persist: persist, host: host).get()
                }
            }, remove: { operations.remove($0) }, currentSSID: { await DjiAppleWiFiJoiner.currentSSID(hotspot) },
                configuredSSIDs: { await hotspot.configuredSSIDs() })
        }
    }

    private static func joinCameraAP(
        ssid: String, passphrase: String, wpa3: Bool, knownOtherSSIDs: [String], persist: Bool,
        host: DjiAppleTransportHost, mutations: Mutations
    ) async throws {
        try Task.checkCancellation()
        var kick = Set(knownOtherSSIDs.filter { !$0.isEmpty && $0 != ssid })
        let joined = await mutations.currentSSID()
        try Task.checkCancellation()
        if CameraSoftAPSwitch.isAlreadyJoined(
            currentSSID: joined, target: ssid, pathReady: isCameraPathReady())
        {
            // Applying again (other settings, e.g. join-once from the first pairing) asks the
            // operator "Wants to Join" for the network the phone is already on.
            host.journal("wifi: already on \(ssid) with a camera address, no apply")
            return
        }
        leave(ssids: Array(kick), mutations: mutations)
        await leaveOtherOsmoSoftAPs(except: ssid, host: host, mutations: mutations)

        let deadline = Date().addingTimeInterval(CameraSoftAPSwitch.joinDeadlineSeconds)
        var lastError: Error = JoinError.pathNotReady
        var applyAnswered = true
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let current = await mutations.currentSSID()
            try Task.checkCancellation()
            if let foreign = CameraSoftAPSwitch.ssidToKick(
                currentSSID: current, target: ssid, knownCameraSSIDs: knownOtherSSIDs)
            {
                host.journal("wifi: kick \(foreign) then join \(ssid) #\(attempt)")
                mutations.remove(foreign)
                kick.insert(foreign)
            }
            leave(ssids: Array(kick), mutations: mutations)
            await leaveOtherOsmoSoftAPs(except: ssid, host: host, mutations: mutations)
            try await Task.sleep(for: .milliseconds(250))
            applyAnswered = true
            do {
                try await mutations.apply(
                    ssid, passphrase, wpa3, persist,
                    .seconds(min(20, max(0, deadline.timeIntervalSinceNow))))
                try Task.checkCancellation()
                try await waitUntilCameraPathReady(
                    timeout: min(15, max(0, deadline.timeIntervalSinceNow)), host: host)
                let now = await mutations.currentSSID()
                try Task.checkCancellation()
                if CameraSoftAPSwitch.isOnTarget(currentSSID: now, target: ssid) {
                    host.journal("wifi: on \(ssid) (ssid=\(now ?? "nil")) #\(attempt)")
                    return
                }
                host.journal("wifi: still on ssid=\(now ?? "?") after join \(ssid) - retry")
                if let now,
                    CameraSoftAPSwitch.isCameraNetwork(now, knownCameraSSIDs: knownOtherSSIDs)
                {
                    mutations.remove(now)
                }
                lastError = JoinError.stillOnOtherBody(now ?? "other camera")
            } catch is CancellationError {
                throw CancellationError()
            } catch let refusal as CameraHotspotJoinRefusal where !refusal.retryMayJoin {
                // A decline or a wrong name or key: asking again would only repeat it.
                throw refusal
            } catch JoinError.timedOut {
                // iOS has not answered: "Wants to Join" may still be up. The next apply of this
                // network waits for that answer (CameraHotspotSystem).
                applyAnswered = false
                lastError = JoinError.timedOut
            } catch {
                lastError = error
            }
            let addresses = interfaceAddresses()
            if CameraSoftAP.isPersonalHotspotHosting(addresses), !isCameraPathReady() {
                host.journal(
                    "wifi: Personal Hotspot is on (\(CameraSoftAP.describe(addresses))), stop joining"
                )
                throw JoinError.personalHotspot
            }
            let left = deadline.timeIntervalSinceNow
            guard CameraSoftAPSwitch.shouldRetryJoin(secondsLeft: left) else { throw lastError }
            // 5.8 GHz DFS: the AP may not beacon yet. Drop the config so the next apply associates
            // fresh instead of "already applied", but never under an unanswered system prompt:
            // that removal would undo the operator's Join.
            host.journal(
                "wifi: join \(ssid) #\(attempt) missed (\(lastError.localizedDescription)), retry, \(Int(left)) s left"
            )
            if CameraSoftAPSwitch.retryDropsConfiguration(applyAnswered: applyAnswered) {
                mutations.remove(ssid)
            }
            try await Task.sleep(for: .seconds(CameraSoftAPSwitch.joinRetryPauseSeconds))
        }
    }

    /// The SSID through the host's retained owner when it supplies one.
    public static func currentSSID(host: DjiAppleTransportHost) async -> String? {
        guard let hotspot = host.hotspot else { return await currentSSID() }
        return await currentSSID(hotspot)
    }

    private static func currentSSID(_ hotspot: CameraHotspotHost) async -> String? {
        #if targetEnvironment(simulator)
            return nil
        #else
            return await hotspot.currentSSID()
        #endif
    }

    public static func currentSSID() async -> String? {
        #if targetEnvironment(simulator)
            return nil
        #else
            return try? await awaitCallback(timeout: .seconds(3)) { completion in
                NEHotspotNetwork.fetchCurrent { network in
                    completion(.success(network?.ssid))
                }
            }
        #endif
    }

    public static func join(
        ssid: String,
        passphrase: String,
        wpa3: Bool,
        persist: Bool = false,
        timeout: Duration = .seconds(20),
        host: DjiAppleTransportHost = .init(),
        isCurrent: @escaping CameraNetworkIsCurrent = { true }
    ) async throws {
        if let hotspot = host.hotspot {
            // One apply, serialized behind any join of this host's owner still pending natively.
            try await hotspot.withAttempt(isCurrent) { operations in
                try await Mutations.shared(hotspot, operations, host: host)
                    .apply(ssid, passphrase, wpa3, persist, timeout)
            }
            return
        }
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        // Join-once drops the hotspot when the app leaves the foreground; saved
        // cameras need the config to survive Control Center / background.
        config.joinOnce = !persist
        try await awaitCallback(timeout: timeout) {
            (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                completion(applyOutcome(error as NSError?, ssid: ssid, persist: persist, host: host))
            }
        }
    }

    private nonisolated static func applyOutcome(
        _ error: NSError?, ssid: String, persist: Bool, host: DjiAppleTransportHost
    ) -> Result<Void, Error> {
        guard let error else {
            // nil error is "config applied", not "associated" - a wrong
            // passphrase still returns here and iOS shows Unable to join.
            host.journal("wifi: apply \(ssid) ok persist=\(persist)")
            return .success(())
        }
        // "already associated" is success, not a failure.
        if error.domain == NEHotspotConfigurationErrorDomain,
            error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
        {
            host.journal("wifi: apply \(ssid) already associated")
            return .success(())
        }
        if let refusal = CameraHotspotJoinRefusal(error: error, network: ssid) {
            host.journal("wifi: join refused \(refusal.diagnosticsCode)")
            return .failure(refusal)
        }
        // No platform text in operator copy; the code stays in the journal above.
        host.journal("wifi: apply \(ssid) failed \(error.domain) \(error.code)")
        return .failure(JoinError.failed("the system refused the request"))
    }

    /// True when this phone has a DHCP address on the camera AP.
    /// Simulator has no SoftAP - treat as ready so connect UI can still run.
    public static func isCameraPathReady() -> Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return CameraSoftAP.isPathReady(localIPv4s: ipv4Addresses())
        #endif
    }

    /// Block until `192.168.2.2…254` exists. Second connect returns immediately.
    public static func waitUntilCameraPathReady(timeout: TimeInterval = 15, host: DjiAppleTransportHost = .init()) async throws {
        try Task.checkCancellation()
        if isCameraPathReady() { return }
        host.journal("wifi: waiting for 192.168.2.x (first join / DHCP)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if isCameraPathReady() {
                try await Task.sleep(for: .milliseconds(200))
                if isCameraPathReady() {
                    host.journal(
                        "wifi: camera path ready (\(CameraSoftAP.describe(CameraSoftAP.cameraAddresses(in: interfaceAddresses()))))"
                    )
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let current = await currentSSID(host: host) ?? "nil"
        host.journal(
            "wifi: no 192.168.2.x after \(Int(timeout)) s ssid=\(current) ipv4=\(CameraSoftAP.describe(interfaceAddresses()))"
        )
        throw JoinError.pathNotReady
    }

    public static func leave(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    public static func leave(ssids: [String]) {
        for ssid in Set(ssids) where !ssid.isEmpty {
            leave(ssid: ssid)
        }
    }

    /// Leaves through the host's retained owner, which drops the removal if `isCurrent` turns
    /// false while a native join is still pending. Without an owner, the original direct call.
    public static func leave(
        ssid: String, host: DjiAppleTransportHost, isCurrent: @escaping CameraNetworkIsCurrent = { true }
    ) {
        if let hotspot = host.hotspot { hotspot.remove(ssid, isCurrent) }
        else if isCurrent() { leave(ssid: ssid) }
    }

    private static func leave(ssids: [String], mutations: Mutations) {
        for ssid in Set(ssids) where !ssid.isEmpty {
            mutations.remove(ssid)
        }
    }

    /// Pocket and Nano SoftAPs are both `192.168.2.1`. Drop every configured
    /// Osmo hotspot except the one we are about to join so iOS cannot stay
    /// on the other body. The other camera can stay powered on.
    public static func leaveOtherOsmoSoftAPs(except keep: String, host: DjiAppleTransportHost = .init()) async {
        await leaveOtherOsmoSoftAPs(except: keep, host: host, mutations: .legacy(host))
    }

    private static func leaveOtherOsmoSoftAPs(
        except keep: String, host: DjiAppleTransportHost, mutations: Mutations
    ) async {
        let configured = await mutations.configuredSSIDs()
        guard !Task.isCancelled else { return }
        let extras = configured.filter { $0 != keep && CameraSoftAP.isOsmoSoftAPSSID($0) }
        if !extras.isEmpty {
            host.journal(
                "wifi: removing other Osmo SoftAPs \(extras.joined(separator: ","))"
            )
            leave(ssids: extras, mutations: mutations)
        }
    }

    public static func configuredSSIDs() async -> [String] {
        (try? await awaitCallback(timeout: .seconds(3)) { completion in
            NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
                completion(.success(ssids))
            }
        }) ?? []
    }

    /// NEHotspot callbacks have no Swift task cancellation contract. Resolve
    /// once, bound the OS wait, and ignore late completions from an abandoned join.
    public static func awaitCallback<Value: Sendable>(
        timeout: Duration,
        register: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let waiter = DjiAppleCallbackWaiter<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let deadlineTask = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                waiter.resolve(.failure(JoinError.timedOut))
            }
            defer { deadlineTask.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                guard !Task.isCancelled else {
                    waiter.resolve(.failure(CancellationError()))
                    return
                }
                register { waiter.resolve($0) }
            }
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
        }
    }

    /// After leaving another body's SoftAP, wait until `192.168.2.x` is gone
    /// so the next join cannot inherit that path.
    public static func waitUntilCameraPathGone(timeout: TimeInterval = 6, host: DjiAppleTransportHost = .init()) async {
        if !isCameraPathReady() { return }
        host.journal("wifi: waiting for 192.168.2.x to drop after leaving the other AP")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return }
            if !isCameraPathReady() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        host.journal("wifi: 192.168.2.x still present after leave")
    }

    public static func ipv4Addresses() -> [String] {
        interfaceAddresses().map(\.ipv4)
    }

    public static func cameraLocalIPv4() -> String? {
        CameraSoftAP.cameraLocalIPv4(in: interfaceAddresses())
    }

    public static func cameraInterfaceNames() -> [String] {
        CameraSoftAP.cameraInterfaceNames(in: interfaceAddresses())
    }

    public static func interfaceAddresses() -> [CameraSoftAP.InterfaceAddress] {
        var addrs: [CameraSoftAP.InterfaceAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(first) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            defer { ptr = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let ok = getnameinfo(
                sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST)
            if ok == 0 {
                addrs.append(
                    .init(
                        name: String(cString: ifa.pointee.ifa_name),
                        ipv4: String(cString: host)))
            }
        }
        return addrs
    }

    /// NWInterface that owns `192.168.2.2…254`. Nil if the SoftAP is not in the
    /// default path - caller still binds `requiredLocalEndpoint` to that IPv4.
    public static func resolveCameraInterface(timeout: TimeInterval = 2) async -> NWInterface? {
        let names = Set(cameraInterfaceNames())
        guard !names.isEmpty else { return nil }
        return try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<NWInterface?, Error>) in
            let monitor = NWPathMonitor()
            let q = DispatchQueue(label: "opv.wifi.camera-if")
            let waiter = DjiAppleCallbackWaiter<NWInterface?>()
            // This path observation cannot fail; the wrapper preserves the nonthrowing interface.
            waiter.install(cont)
            let finish: @Sendable (NWInterface?) -> Void = { iface in
                monitor.cancel()
                waiter.resolve(.success(iface))
            }
            monitor.pathUpdateHandler = { path in
                if let iface = path.availableInterfaces.first(where: { names.contains($0.name) }) {
                    finish(iface)
                }
            }
            monitor.start(queue: q)
            q.asyncAfter(deadline: .now() + timeout) {
                let iface = monitor.currentPath.availableInterfaces.first {
                    names.contains($0.name)
                }
                finish(iface)
            }
        }
    }
}

#endif
