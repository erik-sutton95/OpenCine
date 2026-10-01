import Foundation

/// Camera-independent capabilities. Absence means the UI must not promise a camera operation.
public struct CameraCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let liveVideo = Self(rawValue: 1 << 0)
    public static let recording = Self(rawValue: 1 << 1)
    public static let exposure = Self(rawValue: 1 << 2)
    public static let captureFormat = Self(rawValue: 1 << 3)
    public static let whiteBalance = Self(rawValue: 1 << 4)
    public static let focus = Self(rawValue: 1 << 5)
    public static let zoom = Self(rawValue: 1 << 6)
    public static let gimbal = Self(rawValue: 1 << 7)
    public static let cameraMedia = Self(rawValue: 1 << 8)
    public static let liveAudio = Self(rawValue: 1 << 9)
}

public struct MonitorCamera: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let model: String
    public let capabilities: CameraCapabilities
    public init(id: UUID, name: String, model: String, capabilities: CameraCapabilities) {
        self.id = id
        self.name = name
        self.model = model
        self.capabilities = capabilities
    }
}

public enum CameraConnectionPhase: Sendable, Equatable {
    case idle, scanning, connecting, negotiating, awaitingApproval, readingWiFi, joiningWiFi,
        openingVideo, streaming
}

/// Capture metadata is deliberately separate from preview dimensions and delivery rate.
public enum CameraPreviewTransfer: String, Sendable, Codable {
    case rec709, hlg, dLog, dLog2, iLog
}

public struct CameraInformation: Sendable, Equatable {
    public var model: String
    public var firmware: String?
    public var sourceLabel: String?
    public var previewTransfer: CameraPreviewTransfer?
    public init(
        model: String, firmware: String? = nil, sourceLabel: String? = nil,
        previewTransfer: CameraPreviewTransfer? = nil
    ) {
        self.model = model
        self.firmware = firmware
        self.sourceLabel = sourceLabel
        self.previewTransfer = previewTransfer
    }
}

public enum CameraBackendEvent: Sendable {
    case discovered(MonitorCamera)
    case phase(CameraConnectionPhase)
    case information(CameraInformation)
    case joinedWiFi(ssid: String)
    case videoAccessUnit(Data, timestampMilliseconds: UInt64)
    case disconnected(reason: String)
    case note(String)
}

/// Discovery, connection, picture and media seam used by the shared Apple presentation facade.
/// Backends own authorization, credentials, network association and transport lifetime.
/// The UI owns decode/render, monitor assists, layout, library cache and operator preferences.
///
/// Camera commands and camera-reported state are not part of this protocol: they go through the
/// integration's OpenCineCore `CameraSession` (explicit intents, receipts, observations). The
/// former `apply(_:)` intent path and `.status` event were never implemented and were removed
/// so there is one command contract.
@MainActor
public protocol CameraBackend: AnyObject {
    var capabilities: CameraCapabilities { get }
    var eventHandler: ((CameraBackendEvent) -> Void)? { get set }
    var isOnCameraNetwork: Bool { get }
    func startScan() async throws
    func connect(to camera: MonitorCamera) async throws
    func disconnect()
    func forget(cameraID: UUID)
    func leaveCameraNetwork()
    func rejoinCameraNetwork() async throws
    func refreshStatus() async throws
    func listMedia() async throws -> [CameraMediaAsset]
    func downloadMedia(
        _ asset: CameraMediaAsset, representation: CameraMediaRepresentation, to destination: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void) async throws
    func deleteMedia(_ asset: CameraMediaAsset) async throws
}

/// Explicit preview/test default; it never pretends to be a connected camera.
@MainActor
public final class UnavailableCameraBackend: CameraBackend {
    public let capabilities: CameraCapabilities = []
    public var eventHandler: ((CameraBackendEvent) -> Void)?
    public var isOnCameraNetwork: Bool { false }
    public init() {}
    public func startScan() async throws {
        throw CameraBackendError.unavailable("No camera adapter is configured.")
    }
    public func connect(to camera: MonitorCamera) async throws {
        throw CameraBackendError.unavailable("No camera adapter is configured.")
    }
    public func disconnect() { eventHandler?(.phase(.idle)) }
    public func forget(cameraID: UUID) {}
    public func leaveCameraNetwork() {}
    public func rejoinCameraNetwork() async throws {
        throw CameraBackendError.unavailable("No camera adapter is configured.")
    }
}

public enum CameraBackendError: LocalizedError, Sendable {
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

public struct CameraMediaAsset: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let filename: String
    public let bytes: UInt64?
    public let durationSeconds: Double?
    public let capturedAt: Date?
    public let resolution: String?
    public let framesPerSecond: Double?
    public let isPhoto: Bool
    public let canDelete: Bool
    public init(
        id: String, filename: String, bytes: UInt64? = nil, durationSeconds: Double? = nil,
        capturedAt: Date? = nil, resolution: String? = nil, framesPerSecond: Double? = nil,
        isPhoto: Bool = false, canDelete: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.bytes = bytes
        self.durationSeconds = durationSeconds
        self.capturedAt = capturedAt
        self.resolution = resolution
        self.framesPerSecond = framesPerSecond
        self.isPhoto = isPhoto
        self.canDelete = canDelete
    }
}
public enum CameraMediaRepresentation: Sendable, Equatable { case thumbnail, proxy, original }
extension CameraBackend {
    public func refreshStatus() async throws {}
    public func listMedia() async throws -> [CameraMediaAsset] {
        throw CameraBackendError.unavailable("Camera media access is not connected yet.")
    }
    public func downloadMedia(
        _ asset: CameraMediaAsset, representation: CameraMediaRepresentation, to destination: URL,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        throw CameraBackendError.unavailable("Camera media downloading is not connected yet.")
    }
    public func deleteMedia(_ asset: CameraMediaAsset) async throws {
        throw CameraBackendError.unavailable("Camera media deletion is not connected yet.")
    }
}
