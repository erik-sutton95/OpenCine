import Foundation
import OpenCineGyro

/// Feeds Nikon live-view and property observations to shared gyro capture.
@MainActor public final class NikonGyroCameraAdapter: GyroCameraAdapter {
    private let write: @MainActor ([PTPCameraPropertyWrite]) async -> Bool
    private weak var sink: (any GyroCameraSink)?
    private var lastRecording: Bool?
    private var hasSnapshot = false
    private var lastStabilization: GyroStabilizationState?
    private var lastVideoMode: Bool?
    private var lastIdentity: GyroCameraIdentity?
    private var lastRecordingTimestamp: Double?

    /// Creates an adapter whose stabilization writes use the host's serialized camera queue.
    public init(write: @escaping @MainActor ([PTPCameraPropertyWrite]) async -> Bool) {
        self.write = write
    }

    /// Nikon live view can carry virtual-horizon readings.
    public let providesLevel = true

    /// Movie VR and electronic VR settings restored after an armed session.
    public var stabilizationSettings: [GyroStabilizationSetting] { NikonGyroCamera.settings }

    /// Starts forwarding observations to one sink and replays the current camera state.
    public func attach(_ sink: any GyroCameraSink) {
        self.sink = sink
        if let lastIdentity { sink.receive(.connected(lastIdentity)) }
        if let lastRecording, let lastRecordingTimestamp {
            sink.receive(.recording(lastRecording, at: lastRecordingTimestamp))
        }
        if hasSnapshot {
            sink.receive(.stabilization(lastStabilization))
            sink.receive(.videoMode(lastVideoMode))
        }
    }

    /// Stops forwarding observations.
    public func detach() {
        sink = nil
    }

    /// Writes known stabilization values in their camera-defined order.
    public func writeStabilization(_ values: [String: String]) async -> Bool {
        let writes = NikonGyroCamera.writes(for: values)
        guard writes.count == values.count else { return false }
        guard !writes.isEmpty else { return true }
        return await write(writes)
    }

    /// Publishes the active body identity.
    public func connected(_ identity: NativeCameraIdentity) {
        let identity = NikonGyroCamera.identity(identity)
        lastIdentity = identity
        sink?.receive(.connected(identity))
    }

    /// Publishes disconnection and resets event deduplication for the next body session.
    public func disconnected() {
        sink?.receive(.disconnected)
        lastRecording = nil
        lastRecordingTimestamp = nil
        hasSnapshot = false
        lastStabilization = nil
        lastVideoMode = nil
        lastIdentity = nil
    }

    /// Publishes recording changes and every level reading at the host's monotonic timestamp.
    public func receive(frame: PTPLiveViewFrame, at timestamp: Double) {
        lastRecordingTimestamp = timestamp
        if lastRecording != frame.isRecording {
            lastRecording = frame.isRecording
            sink?.receive(.recording(frame.isRecording, at: timestamp))
        }
        sink?.receive(.level(NikonGyroCamera.cameraDown(from: frame.level), at: timestamp))
    }

    /// Publishes only changed stabilization and movie-mode observations.
    public func receive(snapshot: PTPCameraPropertySnapshot) {
        let stabilization = NikonGyroCamera.stabilization(from: snapshot)
        let videoMode = NikonGyroCamera.videoMode(from: snapshot)
        if !hasSnapshot || stabilization != lastStabilization {
            sink?.receive(.stabilization(stabilization))
        }
        if !hasSnapshot || videoMode != lastVideoMode {
            sink?.receive(.videoMode(videoMode))
        }
        hasSnapshot = true
        lastStabilization = stabilization
        lastVideoMode = videoMode
    }
}
