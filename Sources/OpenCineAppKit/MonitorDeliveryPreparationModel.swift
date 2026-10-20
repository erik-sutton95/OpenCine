import Foundation
import Observation
import OpenCineCore

/// Only the popup's typed options, project lookup and approved route lease. The accepted batch
/// belongs to MonitorDeliveryModel; cache/native preparation never runs in this owner.
@available(macOS 14, *) @MainActor @Observable
public final class MonitorDeliveryPreparationModel<
    Curve: Equatable & Sendable, Format: Equatable & Sendable,
    Project: Sendable, Context: Sendable, Lease: Sendable
> {
    public enum Step { case destination, options }
    public private(set) var step: Step
    public private(set) var destination: MonitorDeliveryDestination?
    public var configuration: MonitorDeliveryExportConfiguration<Curve, Format>?
    public var action: MonitorDeliveryPostExportAction = .systemShare
    public private(set) var selection: MonitorDeliverySelectionFacts
    public private(set) var remoteFacts: MonitorDeliveryRemoteFacts?
    public private(set) var listing: MonitorDeliveryProjectListing<Context, Project>?
    public private(set) var projectsLoading = false
    public private(set) var projectsError: String?
    public private(set) var selectedProjectID: String?
    public private(set) var hopping = false
    public var showCreateProject = false
    public var newProjectName = ""
    public var showHopConfirmation = false
    public let exportOptions: MonitorDeliveryExportOptions<Curve, Format>?
    @ObservationIgnored private let observeSelection: () -> MonitorDeliverySelectionFacts
    @ObservationIgnored private let remote: MonitorDeliveryRemoteService<Project, Context, Lease>?
    @ObservationIgnored private let sourceCurrent: () -> Bool
    @ObservationIgnored private let beforeInternetHop: (() async throws -> Void)?
    @ObservationIgnored private let sleep: (Duration) async throws -> Void
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var begun = false
    @ObservationIgnored private var projectsRequest: UUID?
    @ObservationIgnored private var hopRequest: UUID?
    @ObservationIgnored private var projectsTask: Task<Void, Never>?
    @ObservationIgnored private var hopTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var lease: Lease?

    public convenience init(
        selection: @escaping () -> MonitorDeliverySelectionFacts,
        configuration: MonitorDeliveryExportConfiguration<Curve, Format>?,
        exportOptions: MonitorDeliveryExportOptions<Curve, Format>?,
        remote: MonitorDeliveryRemoteService<Project, Context, Lease>? = nil,
        preferredDestination: MonitorDeliveryDestination? = nil,
        sourceCurrent: @escaping () -> Bool,
        sleep: @escaping (Duration) async throws -> Void = hostSleep(for:)
    ) {
        self.init(
            selection: selection, configuration: configuration, exportOptions: exportOptions,
            remote: remote, preferredDestination: preferredDestination,
            sourceCurrent: sourceCurrent,
            beforeInternetHop: nil, sleep: sleep)
    }
    public init(
        selection: @escaping () -> MonitorDeliverySelectionFacts,
        configuration: MonitorDeliveryExportConfiguration<Curve, Format>?,
        exportOptions: MonitorDeliveryExportOptions<Curve, Format>?,
        remote: MonitorDeliveryRemoteService<Project, Context, Lease>? = nil,
        preferredDestination: MonitorDeliveryDestination? = nil,
        sourceCurrent: @escaping () -> Bool,
        beforeInternetHop: (() async throws -> Void)?,
        sleep: @escaping (Duration) async throws -> Void = hostSleep(for:)
    ) {
        observeSelection = selection
        self.selection = selection()
        self.configuration = configuration
        self.exportOptions = exportOptions
        self.remote = remote
        self.sourceCurrent = sourceCurrent
        self.sleep = sleep
        self.beforeInternetHop = beforeInternetHop
        destination = preferredDestination
        step = preferredDestination == nil ? .destination : .options
    }
    /// The export options the selection can use: none when every file is a still (ZIB-469).
    public var clipExportOptions: MonitorDeliveryExportOptions<Curve, Format>? {
        selection.allStills ? nil : exportOptions
    }
    public var remotePresentation: MonitorDeliveryRemotePresentation? { remote?.presentation }
    /// Re-upload is a choice only where the remote skips already uploaded records.
    public var offersReupload: Bool { destination == .remoteUpload && remote?.skipsUploaded == true }
    public var selectedProject: MonitorDeliveryProject<Project>? {
        listing?.projects.first { $0.id == selectedProjectID }
    }
    public var uploadableProjects: [MonitorDeliveryProject<Project>] {
        listing?.projects.filter { $0.uploadable == true } ?? []
    }
    public var internetGate: Bool {
        destination == .remoteUpload && remoteFacts?.onCameraNetwork == true
    }
    public var canContinue: Bool {
        guard destination != nil, selection.hasDeliverable, !hopping, !closed else { return false }
        if exportOptions != nil && configuration == nil { return false }
        if let configuration {
            if configuration.bakeLUT && clipExportOptions?.lutAvailable() != true { return false }
            if configuration.convertLog && clipExportOptions?.convertLogAvailable() != true {
                return false
            }
        }
        guard destination == .remoteUpload else { return true }
        return remoteFacts?.connected == true
            && (selectedProject?.uploadable == true || remoteFacts?.savedProjectID != nil
                || remoteFacts?.onCameraNetwork == true)
    }
    public func destinationEnabled(_ value: MonitorDeliveryDestination) -> Bool {
        guard !closed, selection.hasDeliverable else { return false }
        return value == .nativeShare
            || (remote != nil && remoteFacts?.configured == true && remoteFacts?.connected == true)
    }
    public func start() {
        guard !begun, !closed else { return }
        begun = true
        let captured = epoch
        guard current(captured) else { return }
        refresh(captured)
        guard current(captured) else { return }
        if clipExportOptions?.lutAvailable() != true { configuration?.bakeLUT = false }
        if clipExportOptions?.convertLogAvailable() != true { configuration?.convertLog = false }
        selectedProjectID = remoteFacts?.savedProjectID
        guard current(captured) else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while self.current(captured) && !Task.isCancelled {
                self.refresh(captured)
                guard self.current(captured) else { return }
                if self.step == .options, self.destination == .remoteUpload,
                    self.remoteFacts?.configured == true,
                    self.remoteFacts?.connected == true, self.remoteFacts?.onCameraNetwork == false,
                    self.listing == nil, !self.projectsLoading, self.projectsError == nil
                {
                    self.loadProjects()
                }
                do { try await self.sleep(.seconds(1)) } catch { return }
            }
        }
    }
    public func selectDestination(_ value: MonitorDeliveryDestination) {
        let captured = epoch
        guard current(captured), destinationEnabled(value), current(captured) else { return }
        destination = value
        step = .options
        guard current(captured) else { return }
        if value == .remoteUpload { loadProjects() }
    }
    public func back() {
        let captured = epoch
        guard current(captured) else { return }
        retireProjects()
        guard current(captured), projectsRequest == nil else { return }
        step = .destination
    }
    public func setConvertLog(_ value: Bool) {
        let captured = epoch
        guard current(captured), !value || clipExportOptions?.convertLogAvailable() == true,
            current(captured)
        else { return }
        configuration?.convertLog = value
        if value { configuration?.bakeLUT = false }
    }
    public func setBakeLUT(_ value: Bool) {
        let captured = epoch
        guard current(captured), !value || clipExportOptions?.lutAvailable() == true, current(captured)
        else { return }
        configuration?.bakeLUT = value
        if value { configuration?.convertLog = false }
    }
    public func selectProject(_ id: String) {
        let captured = epoch
        guard current(captured), let listing,
            let project = listing.projects.first(where: { $0.id == id && $0.uploadable == true }),
            let remote
        else { return }
        remote.persist(project, listing.context)
        guard current(captured) else { return }
        selectedProjectID = id
        refresh(captured)
    }
    public func loadProjects() {
        let captured = epoch
        guard current(captured), let remote else { return }
        refresh(captured)
        guard current(captured), destination == .remoteUpload, remoteFacts?.onCameraNetwork == false
        else { return }
        let request = UUID()
        projectsRequest = request
        let old = projectsTask
        projectsTask = nil
        old?.cancel()
        guard current(captured), projectsRequest == request else { return }
        projectsLoading = true
        guard current(captured), projectsRequest == request else { return }
        projectsError = nil
        guard current(captured), projectsRequest == request else { return }
        projectsTask = Task { [weak self] in
            guard let self, self.acceptsProjects(captured, request) else { return }
            do {
                let result = try await remote.load()
                guard self.acceptsProjects(captured, request) else { return }
                let selected =
                    self.selectedProjectID ?? self.remoteFacts?.savedProjectID
                    ?? result.projects.first?.id
                if let project = result.projects.first(where: { $0.id == selected }) {
                    remote.persist(project, result.context)
                    guard self.acceptsProjects(captured, request) else { return }
                }
                self.listing = result
                guard self.acceptsProjects(captured, request) else { return }
                self.selectedProjectID = selected
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsLoading = false
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsTask = nil
            } catch {
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsError = error.localizedDescription
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsLoading = false
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsTask = nil
            }
        }
    }
    public func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        showCreateProject = false
        let captured = epoch
        guard !name.isEmpty, current(captured), let remote, let context = listing?.context else {
            return
        }
        let request = UUID()
        projectsRequest = request
        let old = projectsTask
        projectsTask = nil
        old?.cancel()
        guard acceptsProjects(captured, request) else { return }
        projectsLoading = true
        guard acceptsProjects(captured, request) else { return }
        projectsError = nil
        guard acceptsProjects(captured, request) else { return }
        projectsTask = Task { [weak self] in
            guard let self, self.acceptsProjects(captured, request) else { return }
            do {
                let project = try await remote.create(name, context)
                guard self.acceptsProjects(captured, request) else { return }
                remote.persist(project, context)
                guard self.acceptsProjects(captured, request) else { return }
                self.listing?.projects.insert(project, at: 0)
                guard self.acceptsProjects(captured, request) else { return }
                self.selectedProjectID = project.id
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsLoading = false
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsTask = nil
            } catch {
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsError = error.localizedDescription
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsLoading = false
                guard self.acceptsProjects(captured, request) else { return }
                self.projectsTask = nil
            }
        }
    }
    public func hopToInternet() {
        showHopConfirmation = false
        let captured = epoch
        guard current(captured), let remote else { return }
        let request = UUID()
        hopRequest = request
        let oldTask = hopTask
        let oldLease = lease
        hopTask = nil
        lease = nil
        oldTask?.cancel()
        if let oldLease { remote.internet.restore(oldLease) }
        guard current(captured), hopRequest == request else { return }
        if let beforeInternetHop {
            hopping = true
            guard current(captured), hopRequest == request else { return }
            hopTask = Task { [weak self] in
                guard let self, self.current(captured), self.hopRequest == request,
                    !Task.isCancelled
                else { return }
                do { try await beforeInternetHop() } catch {
                    guard self.current(captured), self.hopRequest == request,
                        !Task.isCancelled
                    else { return }
                    self.hopping = false
                    guard self.current(captured), self.hopRequest == request else { return }
                    self.projectsError = error.localizedDescription
                    guard self.current(captured), self.hopRequest == request else { return }
                    self.hopTask = nil
                    return
                }
                guard self.current(captured), self.hopRequest == request,
                    !Task.isCancelled,
                    let acquired = self.acquireHop(captured, request, remote)
                else { return }
                await self.awaitHop(captured, request, remote, acquired)
            }
            return
        }
        guard let acquired = acquireHop(captured, request, remote) else { return }
        hopTask = Task { [weak self] in
            guard let self else { return }
            await self.awaitHop(captured, request, remote, acquired)
        }
    }
    private func acquireHop(
        _ captured: UUID, _ request: UUID,
        _ remote: MonitorDeliveryRemoteService<Project, Context, Lease>
    ) -> Lease? {
        guard let acquired = remote.internet.begin() else {
            // Another hop holds the route; this popup never steals it.
            guard current(captured), hopRequest == request else { return nil }
            hopping = false
            hopTask = nil
            projectsError = "Couldn't leave the camera's Wi‑Fi while another network switch is running."
            return nil
        }
        guard current(captured), hopRequest == request, remote.internet.owns(acquired),
            current(captured)
        else {
            remote.internet.restore(acquired)
            return nil
        }
        lease = acquired
        hopping = true
        guard current(captured), hopRequest == request else { return nil }
        return acquired
    }
    private func awaitHop(
        _ captured: UUID, _ request: UUID,
        _ remote: MonitorDeliveryRemoteService<Project, Context, Lease>, _ acquired: Lease
    ) async {
        let online = await remote.internet.wait(acquired)
        guard current(captured), hopRequest == request, remote.internet.owns(acquired),
            current(captured)
        else { return }
        hopping = false
        guard current(captured), hopRequest == request else { return }
        hopTask = nil
        guard current(captured), hopRequest == request else { return }
        refresh(captured)
        if online {
            loadProjects()
        } else {
            projectsError =
                "Couldn't reach the internet after leaving the camera's Wi‑Fi. Check cellular or home Wi‑Fi."
        }
    }
    /// Accepts only the caller's already transferred lease. No leave or wait starts here.
    /// On refusal the caller still owns cleanup; success moves cleanup into this popup.
    @discardableResult public func adoptInternetLease(_ acquired: Lease) -> Bool {
        let captured = epoch
        guard current(captured), lease == nil, hopTask == nil, let remote,
            remote.internet.owns(acquired), current(captured),
            remote.internet.owns(acquired), current(captured)
        else { return false }
        lease = acquired
        destination = .remoteUpload
        guard current(captured), remote.internet.owns(acquired), current(captured) else {
            return false
        }
        step = .options
        return current(captured) && remote.internet.owns(acquired) && current(captured)
    }
    public typealias Request = MonitorDeliveryPreparedRequest<Curve, Format, Project, Context, Lease>
    public func takeRequest() -> Request? {
        let captured = epoch
        guard current(captured), canContinue, current(captured), let destination else { return nil }
        var transferred: Lease?
        if let owned = lease, let remote {
            guard remote.internet.owns(owned), current(captured) else { return nil }
            transferred = remote.transfer(owned)
            guard let transferred, current(captured), remote.internet.owns(transferred),
                current(captured)
            else {
                if let transferred { remote.internet.restore(transferred) }
                return nil
            }
            lease = nil
        }
        let remote = destination == .remoteUpload
        let request = Request(
            destination: destination, configuration: configuration, action: action,
            internetLease: transferred, project: remote ? selectedProject : nil,
            projectContext: remote && selectedProject != nil ? listing?.context : nil)
        close()
        return request
    }
    public func close() {
        guard !closed else { return }
        closed = true
        epoch = UUID()
        projectsRequest = nil
        hopRequest = nil
        let oldProjects = projectsTask
        let oldHop = hopTask
        let oldPoll = pollingTask
        let owned = lease
        projectsTask = nil
        hopTask = nil
        pollingTask = nil
        lease = nil
        oldProjects?.cancel()
        oldHop?.cancel()
        oldPoll?.cancel()
        if let owned { remote?.internet.restore(owned) }
    }
    private func refresh(_ captured: UUID) {
        guard current(captured) else { return }
        let facts = observeSelection()
        guard current(captured) else { return }
        selection = facts
        guard current(captured) else { return }
        if let remote {
            let facts = remote.observe()
            guard current(captured) else { return }
            remoteFacts = facts
        }
    }
    private func retireProjects() {
        projectsRequest = nil
        let old = projectsTask
        projectsTask = nil
        projectsLoading = false
        old?.cancel()
    }
    private func acceptsProjects(_ captured: UUID, _ request: UUID) -> Bool {
        current(captured) && projectsRequest == request && !Task.isCancelled
    }
    private func current(_ captured: UUID) -> Bool {
        guard !closed, epoch == captured else { return false }
        let accepted = sourceCurrent()
        return accepted && !closed && epoch == captured
    }
}
