import Foundation

public struct MonitorDeliveryFileFacts: Equatable, Sendable {
    public let filename: String
    public let sizeBytes: UInt64?
    public init(filename: String, sizeBytes: UInt64?) {
        self.filename = filename
        self.sizeBytes = sizeBytes
    }
}
public struct MonitorDeliverySelectionFacts: Sendable {
    public let files: [MonitorDeliveryFileFacts]
    public let cachedCount: Int?
    public let connected: Bool?
    public init(files: [MonitorDeliveryFileFacts], cachedCount: Int?, connected: Bool?) {
        self.files = files
        self.cachedCount = cachedCount
        self.connected = connected
    }
    public var hasDeliverable: Bool {
        (cachedCount ?? 0) > 0 || (connected == true && !files.isEmpty)
    }
}
public struct MonitorDeliveryChoice<Value: Equatable & Sendable>: Sendable {
    public let id: String
    public let label: String
    public let value: Value
    public init(id: String, label: String, value: Value) {
        self.id = id
        self.label = label
        self.value = value
    }
}
/// Coherent optional native export facts. An absent service contributes no invented controls.
@MainActor
public struct MonitorDeliveryExportOptions<
    Curve: Equatable & Sendable, Format: Equatable & Sendable
> {
    public let curves: [MonitorDeliveryChoice<Curve>]
    public let formats: [MonitorDeliveryChoice<Format>]
    public let lutAvailable: () -> Bool?
    public let convertLogAvailable: () -> Bool?
    public let lutLabel: () -> String?
    public let convertHelp: String
    public let convertUnavailableHelp: String
    public let filename: (MonitorDeliveryExportConfiguration<Curve, Format>) -> String?
    public let bakeExposureAvailable: () -> Bool?
    public let formatsForRemoteUpload: Bool?
    public init(
        curves: [MonitorDeliveryChoice<Curve>], formats: [MonitorDeliveryChoice<Format>],
        lutAvailable: @escaping () -> Bool?, convertLogAvailable: @escaping () -> Bool?,
        lutLabel: @escaping () -> String?, convertHelp: String, convertUnavailableHelp: String,
        filename: @escaping (MonitorDeliveryExportConfiguration<Curve, Format>) -> String?
    ) {
        self.curves = curves
        self.formats = formats
        self.lutAvailable = lutAvailable
        self.convertLogAvailable = convertLogAvailable
        self.lutLabel = lutLabel
        self.convertHelp = convertHelp
        self.convertUnavailableHelp = convertUnavailableHelp
        self.filename = filename
        self.bakeExposureAvailable = { true }
        self.formatsForRemoteUpload = true
    }
    public init(
        curves: [MonitorDeliveryChoice<Curve>], formats: [MonitorDeliveryChoice<Format>],
        lutAvailable: @escaping () -> Bool?, convertLogAvailable: @escaping () -> Bool?,
        lutLabel: @escaping () -> String?, convertHelp: String, convertUnavailableHelp: String,
        bakeExposureAvailable: @escaping () -> Bool?, formatsForRemoteUpload: Bool?,
        filename: @escaping (MonitorDeliveryExportConfiguration<Curve, Format>) -> String?
    ) {
        self.curves = curves
        self.formats = formats
        self.lutAvailable = lutAvailable
        self.convertLogAvailable = convertLogAvailable
        self.lutLabel = lutLabel
        self.convertHelp = convertHelp
        self.convertUnavailableHelp = convertUnavailableHelp
        self.filename = filename
        self.bakeExposureAvailable = bakeExposureAvailable
        self.formatsForRemoteUpload = formatsForRemoteUpload
    }
}
public struct MonitorDeliveryProject<Payload: Sendable>: Sendable {
    public let id: String
    public let name: String
    public let uploadable: Bool?
    public let payload: Payload
    public init(id: String, name: String, uploadable: Bool?, payload: Payload) {
        self.id = id
        self.name = name
        self.uploadable = uploadable
        self.payload = payload
    }
}
public struct MonitorDeliveryProjectListing<Context: Sendable, Project: Sendable>: Sendable {
    public let context: Context
    public var projects: [MonitorDeliveryProject<Project>]
    public init(context: Context, projects: [MonitorDeliveryProject<Project>]) {
        self.context = context
        self.projects = projects
    }
}
public struct MonitorDeliveryRemoteFacts: Equatable, Sendable {
    public let configured: Bool?
    public let connected: Bool?
    public let onCameraNetwork: Bool?
    public let savedProjectID: String?
    public let savedProjectName: String?
    public init(
        configured: Bool?, connected: Bool?, onCameraNetwork: Bool?, savedProjectID: String?,
        savedProjectName: String?
    ) {
        self.configured = configured
        self.connected = connected
        self.onCameraNetwork = onCameraNetwork
        self.savedProjectID = savedProjectID
        self.savedProjectName = savedProjectName
    }
}
public struct MonitorDeliveryRemotePresentation: Equatable, Sendable {
    public let displayName: String
    public let progressCaption: String
    public init(displayName: String, progressCaption: String) {
        self.displayName = displayName
        self.progressCaption = progressCaption
    }
}
/// Project/account and route IO stay in actual SDK adapters. The popup owns only their lifetime.
@MainActor
public struct MonitorDeliveryRemoteService<Project: Sendable, Context: Sendable, Lease: Sendable> {
    public let presentation: MonitorDeliveryRemotePresentation
    public let observe: () -> MonitorDeliveryRemoteFacts
    public let load: () async throws -> MonitorDeliveryProjectListing<Context, Project>
    public let create: (String, Context) async throws -> MonitorDeliveryProject<Project>
    public let persist: (MonitorDeliveryProject<Project>, Context) -> Void
    public let internet: MonitorDeliveryInternetService<Lease>
    public let transfer: (Lease) -> Lease?
    public init(
        presentation: MonitorDeliveryRemotePresentation,
        observe: @escaping () -> MonitorDeliveryRemoteFacts,
        load: @escaping () async throws -> MonitorDeliveryProjectListing<Context, Project>,
        create: @escaping (String, Context) async throws -> MonitorDeliveryProject<Project>,
        persist: @escaping (MonitorDeliveryProject<Project>, Context) -> Void,
        internet: MonitorDeliveryInternetService<Lease>, transfer: @escaping (Lease) -> Lease?
    ) {
        self.presentation = presentation
        self.observe = observe
        self.load = load
        self.create = create
        self.persist = persist
        self.internet = internet
        self.transfer = transfer
    }
}
public struct MonitorDeliveryPreparedRequest<Curve: Sendable, Format: Sendable, Lease: Sendable>:
    Sendable
{
    public let destination: MonitorDeliveryDestination
    public let configuration: MonitorDeliveryExportConfiguration<Curve, Format>?
    public let action: MonitorDeliveryPostExportAction
    public let internetLease: Lease?
}
