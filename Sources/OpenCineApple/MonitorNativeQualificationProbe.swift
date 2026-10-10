#if canImport(UIKit)
import AVFoundation
import Foundation
import OpenCineMedia
import UIKit

/// Read-only facts from the actual native source and camera reports, used by opted-in device tests.
/// Missing counters and reports remain unknown. A source timestamp excludes cached repaint.
public struct MonitorNativeQualificationSnapshot: Codable, Sendable {
    public enum Role: String, Codable, Sendable { case live, playback }
    public var role: Role
    public var pictureBounds: [Double]?
    public var playbackItemIdentity: String?
    public var playbackOwnerToken: String?
    public var playbackPosition: Double?
    public var nativePictureReady: Bool?
    public var simulated: Bool
    public var sourceIdentity: String?
    public var sourceActive: Bool?
    public var sourceFrameAt: TimeInterval?
    public var sourcePresentations: Int?
    public var nativeDecodeOutputs: Int?
    public var cameraRecording: Bool?
    public var cameraISO: Int?
    public var cameraISOIsAuto: Bool?

    public init(
        simulated: Bool, role: Role = .live, sourceIdentity: String?, sourceActive: Bool?,
        sourceFrameAt: TimeInterval?, sourcePresentations: Int? = nil,
        nativeDecodeOutputs: Int? = nil, cameraRecording: Bool?, cameraISO: Int?,
        cameraISOIsAuto: Bool? = nil
    ) {
        self.role = role
        pictureBounds = nil
        playbackItemIdentity = nil
        playbackOwnerToken = nil
        playbackPosition = nil
        nativePictureReady = nil
        self.simulated = simulated
        self.sourceIdentity = sourceIdentity
        self.sourceActive = sourceActive
        self.sourceFrameAt = sourceFrameAt
        self.sourcePresentations = sourcePresentations
        self.nativeDecodeOutputs = nativeDecodeOutputs
        self.cameraRecording = cameraRecording
        self.cameraISO = cameraISO
        self.cameraISOIsAuto = cameraISOIsAuto
    }
    /// Reads an existing player and picture layer. It creates no output, decoder or polling task.
    @MainActor public static func playback(
        player: AVPlayer, layer: AVPlayerLayer, sourcePresented: Bool = false,
        itemToken: MonitorPlaybackItemToken? = nil
    ) -> MonitorNativeQualificationSnapshot? {
        guard layer.player === player, let item = player.currentItem,
            item.status == .readyToPlay
        else { return nil }
        #if targetEnvironment(simulator)
        let simulated = true
        #else
        let simulated = false
        #endif
        let identity = String(describing: ObjectIdentifier(item))
        var value = MonitorNativeQualificationSnapshot(
            simulated: simulated, role: .playback, sourceIdentity: identity,
            sourceActive: true, sourceFrameAt: nil, cameraRecording: nil, cameraISO: nil)
        value.playbackItemIdentity = identity
        value.playbackOwnerToken = itemToken.map { "\($0.owner.uuidString):\($0.revision)" }
        let position = player.currentTime()
        value.playbackPosition = position.isNumeric ? position.seconds : nil
        value.nativePictureReady = layer.isReadyForDisplay || sourcePresented
        return value
    }
}

/// A per-picture accessibility probe with no timer, command, global registry or retained source.
/// Release builds and normal app launches never install it.
@MainActor
public final class MonitorNativeQualificationProbe: UIView {
    public var snapshot: @MainActor () -> MonitorNativeQualificationSnapshot?

    private init(snapshot: @escaping @MainActor () -> MonitorNativeQualificationSnapshot?) {
        self.snapshot = snapshot
        super.init(frame: CGRect(x: 1, y: 1, width: 2, height: 2))
        isAccessibilityElement = true
        accessibilityIdentifier = "opencine.native.qualification"
        accessibilityLabel = "Native qualification probe"
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var accessibilityValue: String? {
        get {
            guard window != nil, let picture = superview, var value = snapshot() else { return nil }
            let bounds = picture.convert(picture.bounds, to: nil)
            value.pictureBounds = [Double(bounds.minX), Double(bounds.minY),
                                   Double(bounds.width), Double(bounds.height)]
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {}
    }

    public static func install(
        in picture: UIView,
        snapshot: @escaping @MainActor () -> MonitorNativeQualificationSnapshot?
    ) -> MonitorNativeQualificationProbe? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OPV_PHYSICAL_UI_REVIEW"] == "1" else { return nil }
        let probe = MonitorNativeQualificationProbe(snapshot: snapshot)
        picture.addSubview(probe)
        return probe
        #else
        return nil
        #endif
    }
}
#endif
