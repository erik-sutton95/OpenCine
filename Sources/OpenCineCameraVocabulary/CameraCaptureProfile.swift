import Foundation
import OpenCineCore

/// Declared control facts supplied by a camera integration, separate from live observations.
public struct CameraCaptureProfile: Equatable, Sendable {
    public var labels: CameraLabelProfile
    public var supportsFocusMode: Bool?
    public var supportsTapFocus: Bool?
    public var supportsAperture: Bool?
    public var hasGimbal: Bool?
    public var supportsZoom: Bool?
    public var isoAutoRangeFloor: Int?
    public var videoFormatFallbacks: [ShootingMode: [VideoFormat]]
    public var zoom: CameraZoomProfile?
    public var looks: CameraLUTProfile?
    public var nativeISO: CaptureNativeISOCapabilities
    /// Static support of the families no setting descriptor or flag above carries (ND, face
    /// metering, audio input, photo, camera media, clip delete, multiview, ...). A family not
    /// listed is unknown. `ControlCapabilities` merges this with the live snapshot.
    public var controls: [ControlFamily: SupportStatus] = [:]
    /// Which live header readout carries the app accent. The default keeps the shooting-mode
    /// readout; a body with no shooting-mode readout declares the codec.
    public var headerAccent: MonitorHeaderAccent = .shootingMode

    public init(
        labels: CameraLabelProfile = .standard, supportsFocusMode: Bool? = nil,
        supportsTapFocus: Bool? = nil, supportsAperture: Bool? = nil, hasGimbal: Bool? = nil,
        supportsZoom: Bool? = nil, isoAutoRangeFloor: Int? = nil,
        videoFormatFallbacks: [ShootingMode: [VideoFormat]] = [:], zoom: CameraZoomProfile? = nil,
        looks: CameraLUTProfile? = nil
    ) {
        self.init(labels: labels, supportsFocusMode: supportsFocusMode, supportsTapFocus: supportsTapFocus,
            supportsAperture: supportsAperture, hasGimbal: hasGimbal, supportsZoom: supportsZoom,
            isoAutoRangeFloor: isoAutoRangeFloor, videoFormatFallbacks: videoFormatFallbacks,
            zoom: zoom, looks: looks, nativeISO: .init())
    }

    public init(
        labels: CameraLabelProfile = .standard, supportsFocusMode: Bool? = nil,
        supportsTapFocus: Bool? = nil, supportsAperture: Bool? = nil, hasGimbal: Bool? = nil,
        supportsZoom: Bool? = nil, isoAutoRangeFloor: Int? = nil,
        videoFormatFallbacks: [ShootingMode: [VideoFormat]] = [:], zoom: CameraZoomProfile? = nil,
        looks: CameraLUTProfile? = nil, nativeISO: CaptureNativeISOCapabilities
    ) {
        self.labels = labels
        self.supportsFocusMode = supportsFocusMode
        self.supportsTapFocus = supportsTapFocus
        self.supportsAperture = supportsAperture
        self.hasGimbal = hasGimbal
        self.supportsZoom = supportsZoom
        self.isoAutoRangeFloor = isoAutoRangeFloor
        self.videoFormatFallbacks = videoFormatFallbacks
        self.zoom = zoom
        self.looks = looks
        self.nativeISO = nativeISO
    }
}

/// Ordered zoom choices and declared restrictions. Display names never participate in admission.
public struct CameraZoomProfile: Equatable, Sendable {
    public var stops: [Double]
    public var restrictedModes: Set<ShootingMode>
    public var restrictedStops: [Double]
    public var resolutionCeilings: [VideoResolution: Double]

    public init(stops: [Double], restrictedModes: Set<ShootingMode> = [],
        restrictedStops: [Double] = [1], resolutionCeilings: [VideoResolution: Double] = [:]) {
        self.stops = stops
        self.restrictedModes = restrictedModes
        self.restrictedStops = restrictedStops
        self.resolutionCeilings = resolutionCeilings
    }

    public func choices(resolution: VideoResolution?, shootingMode: Int) -> [Double] {
        if let mode = ShootingMode.fromStatus(shootingMode), restrictedModes.contains(mode) {
            return restrictedStops
        }
        guard let resolution, let ceiling = resolutionCeilings[resolution] else { return stops }
        let offered = stops.filter { $0 <= ceiling }
        return offered.contains(ceiling) ? offered : (offered + [ceiling]).sorted()
    }
}
