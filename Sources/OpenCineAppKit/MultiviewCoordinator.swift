import Foundation
import Observation
import OpenCineCore
import OpenCineMulticam

/// What changed on a member that the app may need to follow (its borrowed editor, its own
/// control session). Kotlin twin: `MultiviewMemberChange`.
public enum MultiviewMemberChange: Hashable, Sendable {
    /// The member's camera was replaced or cleared.
    case camera
    /// The member's control path changed: its control host, or it began connecting or recovering.
    case control
    /// The member was removed: the app clears what it shows for it.
    case removed
}

/// What only the app has, as the coordinator asks for it. Every requirement has a default, so an
/// app adopts only what it offers and the protocol grows (Plan 4: the screen and the tile picture)
/// without breaking an adopter. Kotlin twin: `MultiviewHost`.
@MainActor
public protocol MultiviewHost: AnyObject {
    /// The operator's record confirmation preference (Settings): the stage asks before a record
    /// press when true.
    var confirmsRecord: Bool { get }
    /// Lends `slot`'s member to the app's Live View; false when it could not open.
    func openLiveView(slot: Int) -> Bool
    /// Ends any borrowed Live View; the members keep their links.
    func closeLiveView()
    /// Closes the app's settings editors (their leases are already retired).
    func closeEditors()
    /// A member's camera, control path or membership changed.
    func memberChanged(slot: Int, _ change: MultiviewMemberChange)
    /// The app left (false) or returned to (true) the foreground.
    func applicationActivityChanged(_ active: Bool)
    /// The stage stopped: every member link is closed.
    func stageStopped()
    /// Whether the app shows `slot`'s picture now; repairs wait while it does not.
    func showsPicture(slot: Int) -> Bool
    /// A diagnostic line (never a password).
    func log(_ line: String)
}

extension MultiviewHost {
    public var confirmsRecord: Bool { false }
    public func openLiveView(slot: Int) -> Bool { false }
    public func closeLiveView() {}
    public func closeEditors() {}
    public func memberChanged(slot: Int, _ change: MultiviewMemberChange) {}
    public func applicationActivityChanged(_ active: Bool) {}
    public func stageStopped() {}
    public func showsPicture(slot: Int) -> Bool { true }
    public func log(_ line: String) {}
}

/// One slot's member as the coordinator owns it: its camera, its link's state on the stage, its
/// record state and its recovery budget. The link is the integration's; this is the stage's.
/// Kotlin twin: `MultiviewMember`.
@available(macOS 14, *)
@MainActor @Observable
public final class MultiviewMember<Camera> {
    /// The member's identity, kept through layout, selection and rotation.
    public let id: UUID
    /// The member's picture stream, named for the multicam engine.
    public let stream = StreamID()
    public var entryID: MonitorEntryID { MonitorEntryID(id) }

    public var camera: Camera? {
        didSet {
            if let sameCamera, !sameCamera(oldValue, camera) { onChange?(.camera) }
        }
    }
    /// The identity the camera proved; nil until it did.
    public var identity: [UInt8]?
    /// Where the member was last opened; empty until then.
    public var address = ""
    public var status = MultiviewCopy.addCamera
    public var failureMessage: String?
    public var connecting = false {
        didSet { if connecting { onChange?(.control) } }
    }
    public var recovering = false {
        didSet { if recovering { onChange?(.control) } }
    }
    /// The host the member is controlled through, once its link reported `controlling`.
    public var controlHost: String? {
        didSet { if controlHost != oldValue { onChange?(.control) } }
    }
    public var networkVerified = false
    /// Joined through the experimental shared Wi-Fi path.
    public var experimental = false
    /// The link publishes a picture: from a started preview until the next open, a failed
    /// Reconnect or Remove.
    public var publishing = false
    /// A record command on this member waits for its confirmation.
    public var recordingBusy = false
    /// The camera's record state is fresh enough to plan a record press with.
    public var recordingAvailable = false
    public var recordingNote: String?
    public var lutEnabled = true
    /// When this phone lost the shared network while the member published.
    public var pathLostAt: Date?
    public var budget: RecoveryBudget

    @ObservationIgnored var onChange: (@MainActor (MultiviewMemberChange) -> Void)?
    @ObservationIgnored var sameCamera: (@MainActor (Camera?, Camera?) -> Bool)?
    @ObservationIgnored var repairTask: Task<Void, Never>?

    public init(
        id: UUID = UUID(),
        budget: RecoveryBudget = RecoveryBudget(limit: 2, resetAfterHealthy: .seconds(30))
    ) {
        self.id = id
        self.budget = budget
    }
}

/// Where the stage journal lives (the app's Keychain or preferences). Kotlin twin:
/// `MultiviewJournalStorage`.
public struct MultiviewJournalStorage {
    public var load: @MainActor () -> MultiviewStageJournal.Stage?
    /// Nil deletes it. False when it was not written.
    public var save: @MainActor (MultiviewStageJournal.Stage?) -> Bool

    public init(
        load: @escaping @MainActor () -> MultiviewStageJournal.Stage?,
        save: @escaping @MainActor (MultiviewStageJournal.Stage?) -> Bool
    ) {
        self.load = load
        self.save = save
    }
}

/// The app's saved shared networks. Kotlin twin: `MultiviewNetworkStorage`.
public struct MultiviewNetworkStorage {
    /// The saved password for a network, nil when none is saved.
    public var password: @MainActor (_ ssid: String, _ hotspot: Bool) -> String?
    public var save: @MainActor (StationNetwork) -> Void

    public init(
        password: @escaping @MainActor (_ ssid: String, _ hotspot: Bool) -> String?,
        save: @escaping @MainActor (StationNetwork) -> Void
    ) {
        self.password = password
        self.save = save
    }
}

/// The coordinator's operator copy, the same in every app. Kotlin twin: `MultiviewCopy`.
public enum MultiviewCopy {
    public static let addCamera = "Add camera"
    public static let approveOnCamera = "Connecting · approve on camera"
    public static let connectingPreview = "Connecting normal preview"
    public static let waitingForVideo = "Waiting for video"
    public static let live = "Live · Video mode"
    public static let reconnecting = "Reconnecting…"
    public static let couldNotConnect = "Could not connect"
    public static let couldNotConnectPreview = "Could not connect preview"
    public static let couldNotRestore = "Could not restore preview. Tap Reconnect to try again."
    public static let sharedNetworkLost =
        "Shared network unavailable. Rejoin it, then reconnect this camera."
    public static let notFound =
        "Could not find this camera on the shared Wi-Fi. Check that both devices use the same network and that client isolation is off, then tap Reconnect."
    public static let unavailableAddress =
        "Camera discovery returned an unavailable address. Tap Reconnect to search again."
    public static let unsupportedSubnet =
        "Automatic discovery needs a shared IPv4 network with at most 1,022 device addresses."
    public static let duplicate = "This camera is already in Multiview."
    public static let verifiedWithoutPreview = "Wi-Fi join verified · Preview not supported yet"
    public static let notQualified = "Multiview preview is not available for this camera model yet."
    public static let joinNetworkFirst = "Join the shared Wi-Fi network on this device first."
    public static let notNearby = "Camera is not nearby. Check that it is powered on."
    public static let checkNetwork = "Check the network name and password."
    public static let cleanupNotSaved = "Could not save camera Wi-Fi cleanup. Try again."
    public static let scanCleanupFailed =
        "Camera Wi-Fi could not be restored. Keep it powered on and close Multiview to retry."
    public static let closeCleanupFailed =
        "Some cameras could not return to their own Wi-Fi. Keep them powered on and close Multiview again to retry."

    /// The search line while the stage looks for a member on the shared network.
    public static func finding(attempt: Int, of passes: Int) -> String {
        "Finding camera on Wi-Fi · \(attempt) of \(passes)"
    }
}

/// Why a coordinator step failed, with its operator copy. Kotlin twin: `MultiviewStageFailure`.
public enum MultiviewStageFailure: LocalizedError, Equatable, Sendable {
    /// This phone is not on the shared network.
    case network
    /// No nearby camera to use.
    case unavailable
    /// Another member already holds the camera that answered. Final: the search stops.
    case duplicate
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .network: MultiviewCopy.joinNetworkFirst
        case .unavailable: MultiviewCopy.notNearby
        case .duplicate: MultiviewCopy.duplicate
        case .message(let text): text
        }
    }
}

/// The Bluetooth turns of member repairs: one holder at a time, in request order, never while an
/// add commissions a camera or a network scan uses the radio.
@MainActor
final class MultiviewBluetoothQueue {
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var held = false
    private var nextID: UInt64 = 0
    /// Adds and scans use Bluetooth now.
    var othersUsing: @MainActor () -> Bool = { false }
    /// The stage still runs.
    var open: @MainActor () -> Bool = { true }

    func turn() async -> (@MainActor () -> Void)? {
        guard open() else { return nil }
        if !held, waiters.isEmpty, !othersUsing() {
            held = true
            return release()
        }
        nextID &+= 1
        let id = nextID
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        return granted ? release() : nil
    }

    /// Grants the next turn when Bluetooth is free.
    func pump() {
        guard !waiters.isEmpty else { return }
        guard open() else {
            stop()
            return
        }
        guard !held, !othersUsing() else { return }
        held = true
        waiters.removeFirst().continuation.resume(returning: true)
    }

    /// Answers every waiter with no turn (the stage stopped).
    func stop() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(returning: false) }
    }

    private func release() -> @MainActor () -> Void {
        var released = false
        return { [weak self] in
            guard !released, let self else { return }
            released = true
            self.held = false
            self.pump()
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

/// One Multiview stage: up to `links.count` cameras on one shared network, each through its own
/// member link, with the rules every app shares (the reference Multiview session's rules). It
/// drives cameras only through the Core seams; what only the app has arrives through `host`.
/// Kotlin twin: `MultiviewCoordinator`.
@available(macOS 14, *)
@MainActor @Observable
public final class MultiviewCoordinator<Link: MultiviewMemberLink> where Link.Camera: Sendable {
    public typealias Camera = Link.Camera
    typealias Journal = MultiviewStageJournal

    public let links: [Link]
    public let members: [MultiviewMember<Camera>]
    @ObservationIgnored public weak var host: (any MultiviewHost)?
    /// Layout, selection and Fit/Fill.
    public let presentation: MultiviewStageState

    /// Nearby cameras the Add list offers, as the scanner reported them.
    public var found: [Camera] = []
    /// A network scan holds Bluetooth.
    public var busy = false
    /// This phone is on the shared network.
    public var ready = false
    public var ssid = ""
    public var usePhoneHotspot = false
    public var password = ""
    /// This phone's address on the joined Wi-Fi.
    public var hostAddress = ""
    public var networkConfigured = false
    public var configuringNetwork = false
    public var networkSetupError: String?
    public var error: String?
    public var closing = false
    public var groupRecordingBusy = false
    public var groupRecordingNote: String?
    public var applicationActive = true
    public private(set) var running = false
    /// Settings-editor leases: one per open editor, asked before every setting change.
    @ObservationIgnored public var editorLeases = EditorLeases()

    var pendingReset: [Journal.Camera] = []

    @ObservationIgnored let policy: MultiviewCameraPolicy<Camera>
    @ObservationIgnored let commissioner: (any StationCommissioner<Camera>)?
    @ObservationIgnored let scanner: (any NearbyCameraScanner<Camera>)?
    @ObservationIgnored public let hostPath: any StationHostPath
    @ObservationIgnored let describe: @MainActor (Camera) -> StationCameraRecord
    @ObservationIgnored let journal: MultiviewJournalStorage
    @ObservationIgnored let networks: MultiviewNetworkStorage
    @ObservationIgnored let budget: ResourceBudget
    @ObservationIgnored let sightingAddress: (@MainActor (Camera) -> String?)?
    @ObservationIgnored let failureText: @MainActor (Error) -> String
    @ObservationIgnored let probeWidth: Int
    @ObservationIgnored let clock: HostClock
    @ObservationIgnored let bluetooth = MultiviewBluetoothQueue()

    @ObservationIgnored private var activityGeneration = 0
    @ObservationIgnored private var foregroundAt = Date.distantPast
    @ObservationIgnored private var connectionTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var hostJoin: Task<Void, Error>?
    @ObservationIgnored private var addressReservations: [String: UUID] = [:]
    @ObservationIgnored private var stationResetTasks: [UUID: Task<StationRestoreResult, Never>] = [:]
    @ObservationIgnored private var deferredReturns: [UUID: String] = [:]
    @ObservationIgnored private var cleanupJournalWritten = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var networkScanTask: Task<Void, Error>?
    @ObservationIgnored private var discovering = false
    @ObservationIgnored private var monitor: Task<Void, Never>?

    /// - Parameters:
    ///   - links: one member link per slot, for the stage's lifetime.
    ///   - members: the members, when the app's link objects present their state; else new ones.
    ///   - commissioner: moves a nearby camera onto the network; nil when cameras join only from
    ///     their own menus (the camera is then opened at its sighting and its proof is kept).
    ///   - scanner: nearby discovery for the Add list; nil when the integration has none.
    ///   - describe: the camera's journal record (its id is the camera's identity on the stage).
    ///   - budget: the app's qualification (default: one entry per link).
    ///   - sightingAddress: the address an integration that does not discover by probe saw the
    ///     camera at.
    ///   - failureMessage: the operator copy for a failed add (default: the error's description).
    ///   - probeWidth: probes per batch while searching the subnet.
    public init(
        links: [Link], members: [MultiviewMember<Camera>]? = nil,
        policy: MultiviewCameraPolicy<Camera>,
        commissioner: (any StationCommissioner<Camera>)?,
        scanner: (any NearbyCameraScanner<Camera>)?,
        hostPath: any StationHostPath,
        describe: @escaping @MainActor (Camera) -> StationCameraRecord,
        journal: MultiviewJournalStorage, networks: MultiviewNetworkStorage,
        budget: ResourceBudget? = nil,
        sightingAddress: (@MainActor (Camera) -> String?)? = nil,
        failureMessage: (@MainActor (Error) -> String)? = nil,
        probeWidth: Int = 64, clock: HostClock = .live
    ) {
        let members = members ?? links.map { _ in MultiviewMember<Camera>() }
        precondition(members.count == links.count && !links.isEmpty)
        self.links = links
        self.members = members
        self.policy = policy
        self.commissioner = commissioner
        self.scanner = scanner
        self.hostPath = hostPath
        self.describe = describe
        self.journal = journal
        self.networks = networks
        self.budget = budget ?? ResourceBudget(qualifiedEntries: links.count)
        self.sightingAddress = sightingAddress
        failureText =
            failureMessage ?? { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription }
        self.probeWidth = max(1, probeWidth)
        self.clock = clock
        presentation = MultiviewStageState(slotCount: links.count)
        for slot in links.indices {
            let member = members[slot]
            links[slot].onStatus = { [weak self] status in self?.show(status, slot: slot) }
            member.sameCamera = { [describe] old, new in
                old.map { describe($0).id } == new.map { describe($0).id }
            }
            member.onChange = { [weak self] change in
                self?.host?.memberChanged(slot: slot, change)
            }
        }
        bluetooth.othersUsing = { [weak self] in
            guard let self else { return false }
            return self.busy || self.connectingCameras
        }
        bluetooth.open = { [weak self] in self?.running ?? false }
    }

    // MARK: State

    public var connectingCameras: Bool { members.contains { $0.connecting } }
    var assigned: Bool { members.contains { $0.camera != nil } }
    /// Cleanup is left from an earlier close: the stage is closed and cameras still need to go
    /// back to their own Wi-Fi.
    public var hasPendingCleanup: Bool { !running && !pendingReset.isEmpty && !closing }
    public var stationNetwork: StationNetwork {
        StationNetwork(ssid: ssid, password: password, hotspot: usePhoneHotspot)
    }

    /// The coordinator's half of a member link's status: the member's copy, and the control host
    /// it records once the link's control path is up at the address it was opened at.
    public func show(_ status: MultiviewLinkStatus, slot: Int) {
        let member = members[slot]
        switch status {
        case .opening: member.status = MultiviewCopy.connectingPreview
        case .controlling:
            member.controlHost = member.address
            member.failureMessage = nil
        case .awaitingPicture: member.status = MultiviewCopy.waitingForVideo
        case .live: if member.status != MultiviewCopy.live { member.status = MultiviewCopy.live }
        case .reconnecting: member.status = MultiviewCopy.reconnecting
        }
    }

    func sameCamera(_ a: Camera, _ b: Camera) -> Bool { describe(a).id == describe(b).id }

    // MARK: Lifecycle

    /// Opens the stage: always asks for a network, starts with empty slots, takes presentation and
    /// cleanup from the journal, and runs the 1 s monitor.
    public func start() {
        guard !running else { return }
        running = true
        hostAddress = ""
        ready = false
        networkConfigured = false
        ssid = ""
        password = ""
        usePhoneHotspot = false
        restoreStage()
        scan()
        monitor = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(.seconds(1)) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    /// Stops every link, task and scan. The journal keeps what close needs.
    public func stop() {
        closeEditors()
        persistStage()
        hostJoin?.cancel()
        hostJoin = nil
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        commissioner?.closeCommissions()
        closeLiveView()
        running = false
        setApplicationActive(true)
        monitor?.cancel()
        stopDiscovery()
        networkScanTask?.cancel()
        ready = false
        password = ""
        for slot in links.indices {
            members[slot].repairTask?.cancel()
            links[slot].close()
        }
        bluetooth.stop()
        host?.stageStopped()
    }

    func tick() async {
        ready = hostPath.address(hotspot: usePhoneHotspot) != nil
        for slot in links.indices {
            await links[slot].keepalive()
            let member = members[slot]
            let fresh =
                links[slot].recordReport.map {
                    clock.date().timeIntervalSince($0.receivedAt) < 3
                } == true
            let available = member.controlHost != nil && fresh
            if member.recordingAvailable != available { member.recordingAvailable = available }
            monitorPreview(slot)
        }
    }

    // MARK: Nearby discovery

    /// Nearby discovery feeds the Add list and network setup, and stays up while a camera
    /// connects. A full stage, or an inactive app with nothing connecting, has no consumer for it.
    public static func needsDiscovery(
        running: Bool, applicationActive: Bool, hasEmptySlot: Bool, connecting: Bool
    ) -> Bool {
        running && (hasEmptySlot || connecting) && (applicationActive || connecting)
    }

    private var discoveryNeeded: Bool {
        Self.needsDiscovery(
            running: running && !closing, applicationActive: applicationActive,
            hasEmptySlot: members.contains { $0.camera == nil }, connecting: connectingCameras)
    }

    /// Starts (or restarts) nearby discovery when something needs it, else stops it.
    public func scan() {
        scanTask?.cancel()
        guard discoveryNeeded, let scanner else {
            stopDiscovery()
            return
        }
        discovering = true
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            guard await scanner.waitUntilReady(), !Task.isCancelled, let self else { return }
            self.found.removeAll()
            await scanner.scan { [weak self] camera in
                guard let self, self.scanGeneration == generation else { return }
                if !self.found.contains(where: { self.sameCamera($0, camera) }) {
                    self.found.append(camera)
                }
            }
        }
    }

    private func stopDiscovery() {
        scanTask?.cancel()
        scanGeneration &+= 1
        scanner?.stop()
        discovering = false
    }

    /// Follows demand without restarting a running scan (that clears `found`) or starting one
    /// while a network scan owns the radio.
    func refreshDiscovery() {
        if !discoveryNeeded {
            if discovering { stopDiscovery() }
        } else if !discovering, !busy {
            scan()
        }
    }

    // MARK: Network

    /// The setup wizard's scan through a nearby camera; its cleanup is journaled before the camera
    /// leaves its access point.
    public func scanNetworks(onFound: @escaping @MainActor (String) -> Void) async throws {
        guard running, !closing, !busy, !assigned, let commissioner else {
            throw CancellationError()
        }
        busy = true
        defer {
            busy = false
            networkScanTask = nil
            refreshDiscovery()
            bluetooth.pump()
        }
        let task = Task {
            var camera: Camera?
            for _ in 0..<10 {
                try Task.checkCancellation()
                camera = found.first(where: { policy.hasPreview($0) })
                if camera != nil { break }
                try await clock.sleep(.milliseconds(300))
            }
            guard let camera else { throw MultiviewStageFailure.unavailable }
            stopDiscovery()
            let id = describe(camera).id
            try await commissioner.scanNetworks(
                through: camera,
                beforeStationChange: {
                    guard self.recordStationChange(camera) else {
                        throw MultiviewStageFailure.message(MultiviewCopy.cleanupNotSaved)
                    }
                },
                onRestored: { restored in
                    if restored {
                        self.pendingReset.removeAll { $0.id == id }
                        if self.pendingReset.isEmpty { self.networkSetupError = nil }
                        self.persistStage()
                    } else {
                        self.networkSetupError = MultiviewCopy.scanCleanupFailed
                    }
                }, onFound: onFound)
        }
        networkScanTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Journals `camera` for cleanup before it leaves its own access point.
    @discardableResult public func recordStationChange(_ camera: Camera) -> Bool {
        let record = describe(camera)
        let saved = Journal.Camera(
            slot: 0, id: record.id, name: record.name, modelId: record.modelId, identity: nil,
            deviceAddress: record.deviceAddress, address: "", experimental: false, lutEnabled: false)
        pendingReset = Journal.cleanupTargets(pendingReset, including: [saved])
        return persistStage()
    }

    public func selectNetworkSource(hotspot: Bool) {
        guard !configuringNetwork, !assigned else { return }
        usePhoneHotspot = hotspot
        ssid = ""
        password = ""
        invalidateNetworkConfirmation()
    }

    public func selectNetwork(_ name: String) {
        guard !configuringNetwork, !assigned else { return }
        if ssid != name {
            ssid = name
            password = networks.password(name, usePhoneHotspot) ?? ""
        }
        invalidateNetworkConfirmation()
    }

    private func invalidateNetworkConfirmation() {
        networkConfigured = false
        networkSetupError = nil
        hostAddress = ""
        ready = false
    }

    /// Joins this phone to the chosen Wi-Fi (never to its own hotspot); one join at a time.
    public func joinSharedNetwork() async throws {
        if let hostJoin { return try await hostJoin.value }
        let task = Task { try await self.performHostJoin() }
        hostJoin = task
        defer { hostJoin = nil }
        try await task.value
        try Task.checkCancellation()
        guard running else { throw CancellationError() }
    }

    private func performHostJoin() async throws {
        guard !ssid.isEmpty else { throw MultiviewStageFailure.network }
        // The host phone must not try joining its own hotspot. Its local bridge may appear only
        // after the first camera associates.
        if usePhoneHotspot { return }
        guard
            let address = try await hostPath.join(
                StationNetwork(ssid: ssid, password: password, hotspot: false))
        else { throw MultiviewStageFailure.network }
        hostAddress = address
        ready = true
    }

    /// The wizard's Connect: checks the credentials a camera can carry, joins, saves the network.
    public func configureNetwork() async -> Bool {
        guard !busy, !configuringNetwork, !assigned else { return false }
        configuringNetwork = true
        networkSetupError = nil
        defer { configuringNetwork = false }
        do {
            guard !ssid.isEmpty, ssid.utf8.count <= 32, password.utf8.count <= 63 else {
                throw MultiviewStageFailure.message(MultiviewCopy.checkNetwork)
            }
            try await joinSharedNetwork()
            networks.save(stationNetwork)
            networkConfigured = true
            persistStage()
            return true
        } catch {
            networkSetupError = error.localizedDescription
            return false
        }
    }

    // MARK: Foreground

    /// The app left or returned to the foreground. Members keep their links; repairs wait 3 s
    /// after a return.
    public func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        activityGeneration &+= 1
        host?.log("multiview: scene \(active ? "active" : "inactive")")
        if active { foregroundAt = clock.date() }
        host?.applicationActivityChanged(active)
        refreshDiscovery()
    }

    /// Holds repairs for the foreground grace again (the app rebuilt its pictures).
    public func restartRepairGrace() { foregroundAt = clock.date() }

    // MARK: Members

    /// Starts adding `camera` to `slot` unless that slot is busy.
    public func enqueueAdd(_ camera: Camera, slot: Int, experimental: Bool = false) {
        let member = members[slot]
        guard running, networkConfigured, !closing, member.camera == nil, !member.connecting else {
            return
        }
        connectionTasks[slot]?.cancel()
        connectionTasks[slot] = Task { await self.add(camera, slot: slot, experimental: experimental) }
    }

    /// Adds `camera` to `slot`: the host joins, the commissioner moves the camera onto the shared
    /// network (or, without one, the camera is opened where it was seen), and the camera is found
    /// and identified there before its picture starts.
    public func add(_ camera: Camera, slot: Int, experimental: Bool = false) async {
        let member = members[slot]
        let reasons = ResourceAdmission.reasons(
            admitting: ResourceRequest(entry: member.entryID, device: nil, claims: []),
            qualification: policy.qualification(camera, experimental: experimental),
            alongside: members.filter { $0.camera != nil }.map {
                ResourceRequest(entry: $0.entryID, device: nil, claims: [])
            }, budget: budget)
        guard reasons.isEmpty else {
            error = MultiviewCopy.notQualified
            return
        }
        guard running, networkConfigured, !closing, !busy, !member.connecting,
            member.camera == nil,
            !members.contains(where: { $0.camera.map { sameCamera($0, camera) } == true })
        else { return }
        member.connecting = true
        var client: (any StationCommission)?
        member.camera = camera
        member.experimental = experimental
        member.networkVerified = false
        member.status = MultiviewCopy.approveOnCamera
        refreshDiscovery()
        defer {
            member.connecting = false
            client?.close()
            if running { persistStage() }
            refreshDiscovery()
            bluetooth.pump()
        }
        persistStage()
        var stage = "host Wi-Fi"
        do {
            try await joinSharedNetwork()
            guard let commissioner else {
                stage = "LAN discovery"
                try await discoverPreview(slot, camera: camera, identity: nil)
                networks.save(stationNetwork)
                return
            }
            stage = "Bluetooth pairing"
            let link = try await commissioner.connect(camera) { member.status = $0 }
            client = link
            stage = "camera Wi-Fi identity"
            let identity = try await link.identity()
            stage = "station join"
            let outcome = try await link.join(
                stationNetwork, identity: identity, experimental: experimental,
                progress: { member.status = $0 },
                verifyOnNetwork: {
                    try await self.discoverPreview(slot, camera: camera, identity: identity)
                    return true
                })
            member.identity = identity
            networks.save(stationNetwork)
            if outcome == .verified { return }
            link.close()
            client = nil
            stage = "LAN discovery"
            try await discoverPreview(slot, camera: camera, identity: identity)
        } catch {
            guard running, !Task.isCancelled else { return }
            links[slot].close()
            member.status = MultiviewCopy.couldNotConnect
            member.failureMessage = failureText(error)
            host?.log(
                "multiview: add failed stage=\(stage) error=\((error as NSError).domain)/\((error as NSError).code)"
            )
            // Keep the member for a discovery retry after a successful join.
        }
    }

    /// The operator's Reconnect: the known camera first, then its setup again.
    public func reconnect(slot: Int) async {
        let member = members[slot]
        guard !busy, !member.connecting, !member.recovering, let camera = member.camera else {
            return
        }
        member.failureMessage = nil
        member.budget.reset()
        if member.identity != nil {
            await connectPreview(slot: slot)
            if running, !Task.isCancelled, member.failureMessage != nil { await readd(slot) }
        } else {
            member.camera = nil
            await add(camera, slot: slot, experimental: member.experimental)
        }
    }

    private func readd(_ slot: Int) async {
        let member = members[slot]
        guard let camera = member.camera else { return }
        let experimental = member.experimental
        let lutEnabled = member.lutEnabled
        guard remove(slot: slot) else { return }
        member.lutEnabled = lutEnabled
        await add(camera, slot: slot, experimental: experimental)
    }

    /// Sets the camera up again through the experimental shared Wi-Fi path.
    public func tryExperimentalNetwork(slot: Int) async {
        guard let camera = members[slot].camera, remove(slot: slot) else { return }
        await add(camera, slot: slot, experimental: true)
    }

    /// Finds the member's known camera on the shared network again and restarts its picture.
    public func connectPreview(slot: Int) async {
        let member = members[slot]
        guard running, !closing, !busy, !member.connecting, let camera = member.camera,
            let identity = member.identity
        else { return }
        member.connecting = true
        defer {
            member.connecting = false
            if running { persistStage() }
        }
        do { try await discoverPreview(slot, camera: camera, identity: identity) } catch {
            guard running, !Task.isCancelled else { return }
            links[slot].close()
            member.publishing = false
            member.controlHost = nil
            member.status = MultiviewCopy.couldNotConnectPreview
            member.failureMessage =
                error as? MultiviewStageFailure == .duplicate
                ? MultiviewCopy.duplicate : MultiviewCopy.couldNotRestore
            member.budget.exhaust()
        }
    }

    /// The known address first, then the subnet in two passes (other members excluded), or only
    /// the known address when the integration's cameras are never probed.
    private func discoverPreview(_ slot: Int, camera: Camera, identity: [UInt8]?) async throws {
        let member = members[slot]
        let link = links[slot]
        link.close()
        member.controlHost = nil
        member.recordingAvailable = false
        let excluded = Set(
            members.filter { $0 !== member }.compactMap(\.controlHost).map(policy.hostKey))
        func attempt() async throws -> Bool {
            do {
                try await openPreview(slot, camera: camera, identity: identity)
                return true
            } catch {
                if error is CancellationError || error as? MultiviewStageFailure == .duplicate {
                    throw error
                }
                return false
            }
        }
        if StationSubnet.validAddress(member.address), try await attempt() { return }
        guard policy.discoversByProbe else {
            if let sighted = sightingAddress?(camera), sighted != member.address,
                StationSubnet.validAddress(sighted)
            {
                member.address = sighted
                if try await attempt() { return }
            }
            throw MultiviewStageFailure.message(MultiviewCopy.notFound)
        }
        for pass in 1...2 {
            guard running else { throw CancellationError() }
            member.status = MultiviewCopy.finding(attempt: pass, of: 2)
            let candidates = try await probeCandidates(slot, excluding: excluded)
            for address in candidates {
                guard running else { throw CancellationError() }
                member.address = address
                if try await attempt() { return }
                link.close()
                member.controlHost = nil
            }
            if pass == 1 { try await clock.sleep(.seconds(3)) }
        }
        throw MultiviewStageFailure.message(MultiviewCopy.notFound)
    }

    /// Hosts on this phone's subnet where a camera of `slot`'s integration answers, `probeWidth`
    /// at a time, at most eight.
    private func probeCandidates(_ slot: Int, excluding excluded: Set<String>) async throws
        -> [String]
    {
        guard let local = hostPath.address(hotspot: usePhoneHotspot),
            let mask = hostPath.netmask(hotspot: usePhoneHotspot),
            let all = StationSubnet.hosts(address: local, mask: mask)
        else { throw MultiviewStageFailure.message(MultiviewCopy.unsupportedSubnet) }
        let hosts = all.filter { !excluded.contains(policy.hostKey($0)) }
        let network = stationNetwork
        var found: [String] = []
        for start in stride(from: 0, to: hosts.count, by: probeWidth) {
            try Task.checkCancellation()
            guard running else { throw CancellationError() }
            let batch = Array(hosts[start..<min(start + probeWidth, hosts.count)])
            let probes = batch.map { host in
                Task { @MainActor in await self.links[slot].probe(host, on: network) }
            }
            let answered = await withTaskCancellationHandler {
                var answered: [Bool] = []
                for probe in probes { answered.append(await probe.value) }
                return answered
            } onCancel: {
                for probe in probes { probe.cancel() }
            }
            found += batch.indices.filter { answered[$0] }.map { batch[$0] }
            if found.count >= 8 { break }
        }
        return Array(found.prefix(8))
    }

    private func openPreview(_ slot: Int, camera: Camera, identity: [UInt8]?) async throws {
        let member = members[slot]
        let link = links[slot]
        let address = member.address
        let key = policy.hostKey(address)
        guard addressReservations[key] == nil || addressReservations[key] == member.id else {
            throw MultiviewStageFailure.unavailable
        }
        addressReservations[key] = member.id
        defer {
            if addressReservations[key] == member.id { addressReservations.removeValue(forKey: key) }
        }
        guard running, StationSubnet.validAddress(address),
            !members.contains(where: {
                $0 !== member && $0.controlHost.map(policy.hostKey) == key
            })
        else { throw MultiviewStageFailure.message(MultiviewCopy.unavailableAddress) }
        member.publishing = false
        let proven = try await link.open(
            camera, at: address, expecting: identity, on: stationNetwork)
        guard !members.contains(where: { $0 !== member && $0.identity == proven }) else {
            link.close()
            throw MultiviewStageFailure.duplicate
        }
        guard running else { throw CancellationError() }
        if identity == nil { member.identity = proven }
        member.networkVerified = true
        if !policy.hasPreview(camera) {
            link.close()
            member.failureMessage = nil
            member.status = MultiviewCopy.verifiedWithoutPreview
            host?.log("multiview: experimental LAN identity verified; preview unavailable")
            return
        }
        try await link.startPreview(camera)
        member.publishing = true
    }

    /// Clears `slot`. Its camera stays on the shared network and keeps recording; no camera
    /// command is sent.
    @discardableResult public func remove(slot: Int) -> Bool {
        let member = members[slot]
        guard !busy, !member.connecting, !groupRecordingBusy, !member.recordingBusy else {
            return false
        }
        member.repairTask?.cancel()
        member.repairTask = nil
        member.recovering = false
        member.budget.reset()
        member.pathLostAt = nil
        member.failureMessage = nil
        links[slot].close()
        member.camera = nil
        member.networkVerified = false
        member.experimental = false
        member.lutEnabled = true
        member.identity = nil
        member.controlHost = nil
        member.recordingAvailable = false
        member.recordingNote = nil
        member.publishing = false
        member.status = MultiviewCopy.addCamera
        member.onChange?(.removed)
        persistStage()
        refreshDiscovery()
        return true
    }

    // MARK: Repair

    /// The coordinator's half of repair: when a member may repair, the 45 s path-loss rule, and
    /// the rejoin within the member's budget. The member's link decides and runs the repair.
    private func monitorPreview(_ slot: Int) {
        let member = members[slot]
        let link = links[slot]
        let now = clock.date()
        guard applicationActive, now.timeIntervalSince(foregroundAt) > 3, !busy,
            !member.recovering, !member.budget.exhausted, member.publishing, !member.connecting,
            member.camera != nil, host?.showsPicture(slot: slot) ?? true
        else { return }
        let pathReady = hostPath.address(hotspot: usePhoneHotspot) != nil
        if pathReady {
            member.pathLostAt = nil
        } else if member.pathLostAt == nil {
            member.pathLostAt = now
        }
        let generation = activityGeneration
        let context = MultiviewRepairContext(
            pathReady: pathReady,
            running: { [weak self] in self?.running ?? false },
            applicationActive: { [weak self] in self?.applicationActive ?? false },
            foregroundUnchanged: { [weak self] in self?.activityGeneration == generation },
            pathAvailable: { [weak self] in
                guard let self else { return false }
                return self.hostPath.address(hotspot: self.usePhoneHotspot) != nil
            },
            beginAttempt: { [weak member] in member?.budget.beginAttempt() ?? false },
            observeHealth: { [weak self, weak member] healthy in
                guard let self, let member else { return }
                member.budget.observe(healthy: healthy, at: self.clock.now())
            },
            bluetoothTurn: { [weak self] in await self?.bluetooth.turn() })
        switch link.repair(context) {
        case .healthy:
            if !pathReady, now.timeIntervalSince(member.pathLostAt ?? now) > 45 {
                member.budget.exhaust()
                member.failureMessage = MultiviewCopy.sharedNetworkLost
            }
        case .handled:
            break
        case .waitForOperator(let message):
            waitForOperator(member, message)
        case .repair(let work):
            member.recovering = true
            let deadline = link.repairDeadline
            let sleep = clock.sleep
            member.repairTask = Task { [weak self, weak member] in
                guard let self, let member else { return }
                defer {
                    member.recovering = false
                    member.repairTask = nil
                }
                switch await MultiviewRepairResult.race(deadline: deadline, sleep: sleep, work) {
                case .done: break
                case .rejoin: await self.rejoinWhenAvailable(slot)
                case .waitForOperator(let message): self.waitForOperator(member, message)
                }
            }
        }
    }

    /// No automatic repair remains for this member: it shows why and offers Reconnect.
    private func waitForOperator(_ member: MultiviewMember<Camera>, _ message: String) {
        member.budget.exhaust()
        member.failureMessage = message
    }

    private func rejoinWhenAvailable(_ slot: Int) async {
        let member = members[slot]
        // One discovery owner; waiting members do not spend their budget.
        while busy && running && !Task.isCancelled {
            try? await clock.sleep(.milliseconds(200))
        }
        guard running, !Task.isCancelled, member.camera != nil else { return }
        guard member.budget.beginAttempt() else {
            member.failureMessage = MultiviewCopy.couldNotRestore
            return
        }
        await connectPreview(slot: slot)
    }

    // MARK: Live View and editors

    /// Lends `slot`'s member to the app's Live View once its control path is up. Any settings
    /// editor closes first.
    @discardableResult public func openLiveView(slot: Int) -> Bool {
        closeEditors()
        let member = members[slot]
        guard member.camera != nil, member.controlHost != nil, !member.recovering else {
            return false
        }
        return host?.openLiveView(slot: slot) ?? false
    }

    public func closeLiveView() { host?.closeLiveView() }

    /// Whether the stage admits a settings change on `slot` now (the app adds what only it knows,
    /// such as its link and a borrowed Live View).
    public func controlsAvailable(slot: Int) -> Bool {
        let member = members[slot]
        return member.camera != nil && member.controlHost != nil && !member.connecting
            && !member.recovering && !busy && !closing && applicationActive
            && member.recordingAvailable && !groupRecordingBusy && !member.recordingBusy
    }

    /// Opens the one editor lease on `slot` (closing any other); nil when the member cannot be
    /// edited. The lease names the member's session and control epoch.
    public func openEditorLease(slot: Int) -> EditorLease? {
        closeEditors()
        return try? editorLeases.open(
            members[slot].entryID, in: multicamGroup(of: [slot]), at: multicamSnapshot(of: [slot]))
    }

    /// Whether `lease` still admits a change on `slot` (not retired, member editable).
    public func editorAdmits(_ lease: EditorLease, slot: Int) -> Bool {
        editorLeases.refusal(
            for: lease, in: multicamGroup(of: [slot]), at: multicamSnapshot(of: [slot])) == nil
            && controlsAvailable(slot: slot)
    }

    public func closeEditors() {
        editorLeases.closeAll()
        host?.closeEditors()
    }

    // MARK: Journal

    private func savedCameras() -> [Journal.Camera] {
        members.enumerated().compactMap { slot, member in
            guard let camera = member.camera else { return nil }
            let record = describe(camera)
            return Journal.Camera(
                slot: slot, id: record.id, name: record.name, modelId: record.modelId,
                identity: member.identity, deviceAddress: record.deviceAddress,
                address: member.address, experimental: member.experimental,
                lutEnabled: member.lutEnabled)
        }
    }

    /// Writes the journal: presentation, members and cleanup; deletes it when nothing is left.
    @discardableResult public func persistStage() -> Bool {
        if !networkConfigured, pendingReset.isEmpty {
            guard cleanupJournalWritten else { return true }
            let success = journal.save(nil)
            if success { cleanupJournalWritten = false }
            return success
        }
        let saved = savedCameras()
        let success = journal.save(
            Journal.Stage(
                ssid: networkConfigured ? ssid : "", hotspot: usePhoneHotspot,
                layout: presentation.layout.rawValue, focusedIndex: presentation.selected,
                cameras: saved,
                pendingReset: running && !closing
                    ? Journal.cleanupTargets(pendingReset, including: saved) : pendingReset,
                returnedToCameraWiFi: !running && pendingReset.isEmpty,
                fill: presentation.fill))
        if !success { host?.log("multiview: could not save stage") }
        if success, !networkConfigured { cleanupJournalWritten = true }
        return success
    }

    /// Restores from the saved journal (when valid for this stage's slots).
    public func restoreStage() {
        restoreStage(journal.load().flatMap { $0.validated(tileCount: links.count) })
    }

    /// A new stage always asks for a network and starts with empty slots. A saved stage supplies
    /// presentation and cleanup obligations only; it never chooses a network or reconnects cameras.
    public func restoreStage(_ savedStage: MultiviewStageJournal.Stage?) {
        guard let stage = savedStage else { return }
        pendingReset = stage.pendingReset ?? []
        if stage.returnedToCameraWiFi != true {
            pendingReset = Journal.cleanupTargets(pendingReset, including: stage.cameras)
        }
        cleanupJournalWritten = !pendingReset.isEmpty
        presentation.importLegacy(
            MultiviewStagePreferences(
                layout: MultiviewStageLayout(rawValue: stage.layout) == .grid ? .grid : .centerStage,
                selected: stage.focusedIndex, fill: stage.fill == true))
        // Migrate unfinished camera cleanup before a new camera is added. With no cleanup,
        // retain the last preferences even if setup is cancelled.
        if cleanupJournalWritten { persistStage() }
    }

    // MARK: Close

    /// Closes every member's link first, then returns each camera to its own access point in
    /// parallel. Unfinished returns stay in the journal for the next close.
    public func closeStage() async -> Bool {
        closeEditors()
        guard !closing else { return false }
        closing = true
        networkScanTask?.cancel()
        _ = try? await networkScanTask?.value
        if running {
            pendingReset = Journal.cleanupTargets(pendingReset, including: savedCameras())
        }
        persistStage()
        stop()
        await withTaskGroup(of: Void.self) { group in
            for saved in pendingReset {
                group.addTask { _ = await self.resetStationOnce(saved) }
            }
        }
        persistStage()
        closing = false
        if !pendingReset.isEmpty {
            error =
                pendingReset.lazy.compactMap { self.deferredReturns[$0.id] }.first
                ?? MultiviewCopy.closeCleanupFailed
            return false
        }
        return true
    }

    /// One camera's return, shared by a scan's completion, close and restored cleanup. Its task
    /// survives the caller's cancellation and prevents two returns for the same camera.
    @discardableResult public func resetStationOnce(_ saved: MultiviewStageJournal.Camera) async
        -> Bool
    {
        if let task = stationResetTasks[saved.id] { return await task.value == .restored }
        guard pendingReset.contains(where: { $0.id == saved.id }) else { return true }
        let commissioner = commissioner
        let task = Task {
            let result =
                await commissioner?.restoreAccessPoint(
                    StationCameraRecord(
                        id: saved.id, name: saved.name, modelId: saved.modelId,
                        deviceAddress: saved.deviceAddress)) ?? .restored
            switch result {
            case .restored:
                pendingReset.removeAll { $0.id == saved.id }
                deferredReturns.removeValue(forKey: saved.id)
            case .deferred(let message): deferredReturns[saved.id] = message
            case .failed: deferredReturns.removeValue(forKey: saved.id)
            }
            persistStage()
            stationResetTasks.removeValue(forKey: saved.id)
            return result
        }
        stationResetTasks[saved.id] = task
        return await task.value == .restored
    }
}
