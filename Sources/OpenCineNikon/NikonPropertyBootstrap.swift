import Foundation

/// Wire operations used to populate Nikon's initial monitor observations and setting domains.
/// NativeCameraSession implements them; scripted links verify ordering without a camera.
@MainActor
public protocol NikonBootstrapLink {
    func supportsProperty(_ property: PTPPropertyCode) -> Bool
    func readCameraProperty(_ property: PTPPropertyCode) async throws -> Data
    func writeCameraProperty(_ write: PTPCameraPropertyWrite) async throws
    func changeCameraMode(remote: Bool) async throws
    func readStorageInfo() async throws -> PTPStorageInfo?
    func describeCameraPropertyEnum(_ property: PTPPropertyCode, valueByteCount: Int) async throws
        -> [UInt32]
    func observeCameraPropertyDescriptor(
        _ property: PTPPropertyCode, valueByteCount: Int
    ) async -> NikonDescriptorObservation
    func screenSizeModes() async throws -> [PTPCameraScreenSizeMode]
    func fileTypeModes() async throws -> [PTPCameraFileTypeMode]
    func controlOptions(for property: PTPPropertyCode, valueByteCount: Int) async throws -> [String]
    func stringEnumOptions(for property: PTPPropertyCode) async throws -> [String]
}

extension NikonBootstrapLink {
    /// Existing links without scalar observations remain unknown; labels cannot recover metadata.
    public func observeCameraPropertyDescriptor(
        _ property: PTPPropertyCode, valueByteCount: Int
    ) async -> NikonDescriptorObservation { .init(outcome: .notAttempted) }
}

/// Camera-authored bootstrap values. A consumer caches them for its own display; no value is
/// inferred from a pending app target or substituted for a refused/unknown observation.
public enum NikonBootstrapObservation: Sendable {
    case property(PTPPropertyCode, Data)
    case storage(PTPStorageInfo)
    case apertures([String])
    case screenModes([PTPCameraScreenSizeMode])
    case fileTypes([PTPCameraFileTypeMode])
    case options(PTPPropertyCode, [String])
    /// Exact scalar observation, including unsuccessful attempts; never a substitute option list.
    case descriptor(PTPPropertyCode, NikonDescriptorObservation)
    /// The movie tones one per-codec tone property offers (`NikonMovieToneCapability`).
    case movieTones(PTPPropertyCode, [NikonMovieTone])
    case photographyReady
    case descriptorsReady
}

/// The integration owns initial selector/property/storage/domain reads before StartLiveView.
/// A drifted clock is staged until the first authoritative header says the body is idle.
@MainActor
public final class NikonPropertyBootstrap {
    private let link: any NikonBootstrapLink
    private var clockStaged = false

    public init(link: any NikonBootstrapLink) { self.link = link }

    public func run(
        initial: PTPCameraPropertySnapshot = PTPCameraPropertySnapshot(),
        isCurrent: @MainActor () -> Bool,
        receive: @MainActor (NikonBootstrapObservation) -> Void
    ) async {
        var snapshot = initial
        func read(_ property: PTPPropertyCode) async {
            guard isCurrent(), !Task.isCancelled,
                let data = try? await link.readCameraProperty(property), isCurrent(),
                !Task.isCancelled
            else { return }
            snapshot = snapshot.applying(property: property, data: data)
            receive(.property(property, data))
        }
        await read(.liveViewSelector)
        let order = PTPPropertyCode.monitorPollOrder(
            isRecording: false, captureSelector: snapshot.captureSelector)
        for property in order where property != .liveViewSelector {
            guard isCurrent(), !Task.isCancelled else { return }
            if link.supportsProperty(property) { await read(property) }
        }
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: snapshot.captureSelector)
        if photography {
            try? await link.changeCameraMode(remote: false)
            guard isCurrent(), !Task.isCancelled else { return }
            receive(.photographyReady)
        }
        guard isCurrent(), !Task.isCancelled else { return }
        if let storage = try? await link.readStorageInfo(), isCurrent(), !Task.isCancelled {
            receive(.storage(storage))
        }
        guard isCurrent(), !Task.isCancelled else { return }
        if let raw = try? await link.describeCameraPropertyEnum(
            photography ? .fNumber : .movieFNumber, valueByteCount: 2), isCurrent(),
            !Task.isCancelled
        {
            let apertures = PTPCameraPropertyDecoders.apertureList(fromEnum: raw)
            if !apertures.isEmpty { receive(.apertures(apertures)) }
        }
        guard isCurrent(), !Task.isCancelled else { return }
        if let modes = try? await link.screenSizeModes(), !modes.isEmpty, isCurrent(),
            !Task.isCancelled
        {
            receive(.screenModes(modes))
        }
        guard isCurrent(), !Task.isCancelled else { return }
        if let modes = try? await link.fileTypeModes(), !modes.isEmpty, isCurrent(),
            !Task.isCancelled
        {
            receive(.fileTypes(modes))
        }
        for property in NikonMovieToneCapability.toneProperties {
            guard isCurrent(), !Task.isCancelled else { return }
            guard link.supportsProperty(property),
                let raw = try? await link.describeCameraPropertyEnum(property, valueByteCount: 1),
                isCurrent(), !Task.isCancelled
            else { continue }
            let tones = NikonMovieToneCapability.tones(fromEnum: raw)
            if !tones.isEmpty { receive(.movieTones(property, tones)) }
        }
        let controls = Self.movieControls + (photography ? Self.photoControls : [])
        for (property, width) in controls {
            guard isCurrent(), !Task.isCancelled else { return }
            if property == .movieShutterSpeed, (snapshot.shutterMode ?? .angle) != .speed {
                continue
            }
            if property == .movieShutterAngle, (snapshot.shutterMode ?? .angle) != .angle {
                continue
            }
            if Self.photoControls.contains(where: { $0.0 == property }),
                !link.supportsProperty(property)
            {
                continue
            }
            if var options = try? await link.controlOptions(for: property, valueByteCount: width),
                isCurrent(), !Task.isCancelled
            {
                if property == .movieWhiteBalance {
                    options = options.filter { $0 != "Color temp" }
                }
                if property == .movieFocusMode {
                    options = PTPCameraPropertyDecoders.mergedMovieFocusModeOptions(
                        advertised: options)
                }
                if property == .movieShutterSpeed || property == .movieShutterAngle,
                    options.count <= 1
                {
                    continue
                }
                if !options.isEmpty { receive(.options(property, options)) }
            }
        }
        if photography, link.supportsProperty(.imageSize), isCurrent(), !Task.isCancelled,
            let options = try? await link.stringEnumOptions(for: .imageSize), options.count > 1,
            isCurrent(), !Task.isCancelled
        {
            receive(.options(.imageSize, options))
        }
        if photography, link.supportsProperty(.whiteBalance), isCurrent(), !Task.isCancelled,
            let raw = try? await link.controlOptions(for: .whiteBalance, valueByteCount: 2),
            isCurrent(), !Task.isCancelled
        {
            let options = raw.filter { $0 != "Color temp" }
            if options.count > 1 { receive(.options(.whiteBalance, options)) }
        }
        await observeStabilizationDescriptors(isCurrent: isCurrent, receive: receive)
        guard isCurrent(), !Task.isCancelled else { return }
        receive(.descriptorsReady)
        clockStaged = false
        if let data = try? await link.readCameraProperty(.dateTime), isCurrent(), !Task.isCancelled,
            case .write = CameraClockSync.decide(
                cameraPayload: data, phoneNow: CameraClockSync.phoneNow(), isRecording: false)
        {
            clockStaged = true
        }
    }

    /// Reuses the connected link and its transaction serialization. This observation pass does
    /// not change the legacy option cache, probe writes, retry reads or change discovery policy.
    public func observeStabilizationDescriptors(
        isCurrent: @MainActor () -> Bool,
        receive: @MainActor (NikonBootstrapObservation) -> Void
    ) async {
        for property in [PTPPropertyCode.movieVibrationReduction, .electronicVR] {
            guard isCurrent(), !Task.isCancelled else { return }
            // A known discovery omission is not proof of unsupported camera behavior. Empty
            // discovery lists remain pollable via supportsProperty and still perform the read.
            guard link.supportsProperty(property) else {
                receive(.descriptor(property, .init(outcome: .missing)))
                continue
            }
            receive(.descriptor(property, .init(outcome: .pending)))
            let observation = await link.observeCameraPropertyDescriptor(
                property, valueByteCount: 1)
            guard isCurrent(), !Task.isCancelled else { return }
            receive(.descriptor(property, observation))
        }
    }

    /// Unknown record state waits. The first authoritative recording state consumes this once;
    /// a body already recording keeps its clock untouched for the entire session.
    public func consumeStagedClock(recording: Bool?) async {
        guard clockStaged, let recording else { return }
        clockStaged = false
        guard !recording else { return }
        try? await link.writeCameraProperty(
            PTPCameraPropertyWrite(
                property: .dateTime, data: CameraClockSync.encode(CameraClockSync.phoneNow())))
    }

    private static let movieControls: [(PTPPropertyCode, Int)] = [
        (.movieShutterAngle, 4), (.movieShutterSpeed, 4), (.movieWhiteBalance, 2),
        (.movieFocusMode, 1), (.movieFocusMeteringMode, 2), (.movieAFSubjectDetection, 1),
        (.exposureProgramMode, 2),
    ]
    private static let photoControls: [(PTPPropertyCode, Int)] = [
        (.stillCaptureMode, 2), (.userMode, 1), (.exposureMeteringMode, 2), (.flashMode, 2),
        (.compressionSetting, 1), (.rawCompressionType, 1), (.activePicCtrlItem, 2),
        (.stillFocusMode, 1), (.stillFocusMeteringMode, 2), (.afSubjectDetection, 1),
    ]
}

#if canImport(Darwin) && canImport(os)
    extension NativeCameraSession: NikonBootstrapLink {}
#endif
