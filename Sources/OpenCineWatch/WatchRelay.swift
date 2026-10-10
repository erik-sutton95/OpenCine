#if os(iOS)
import CoreImage
import CoreVideo
import Foundation
import OpenCineApple
import OpenCineRelay
import UIKit
import VideoToolbox
import os

public typealias WatchPreviewPump = RelayPreviewReservations

#if canImport(WatchConnectivity)
private struct WatchNativePreview: @unchecked Sendable {
    let image: CIImage
    let source: CVPixelBuffer?
    let unmanaged: Bool
    let mirrored: Bool
    let flippedVertically: Bool
    let timecode: String
    let isRecording: Bool
}

@MainActor public final class WatchRelay {
    public var onToggleRecord: (@MainActor () -> WatchCommandResult)?
    public var onCapture: (@MainActor () -> WatchCommandResult)?
    public var onAdmittedToggleRecord:
        (@MainActor (RelayWatchCommandAdmission) -> WatchCommandResult)?
    public var onAdmittedCapture:
        (@MainActor (RelayWatchCommandAdmission) -> WatchCommandResult)?
    public var onReachabilityChanged: (@MainActor @Sendable () -> Void)? {
        get { relay.onReachabilityChanged }
        set { relay.onReachabilityChanged = newValue }
    }
    private let relay: WatchPhoneRelay<WatchRelayCodec, WatchNativePreview>
    // Retain the exercised native contexts and identity conversion exactly.
    nonisolated private static let displayContext = CIContext(
        options: MonitorWorkingSpace.displayContextOptions)
    nonisolated private static let lutContext = CIContext(
        options: MonitorWorkingSpace.contextOptions)
    public init() {
        relay = WatchPhoneRelay(codec: WatchRelayCodec(), policy: .init(
            pacing: .init(profiles: [
                .init(maximumWidth: 512, qualityPercent: 48),
                .init(maximumWidth: 416, qualityPercent: 42),
                .init(maximumWidth: 320, qualityPercent: 38),
            ], roundTripThresholds: [0.12, 0.22], initialIndex: 1,
                initialRoundTripHint: 0.12, maximumSampleSeconds: 5),
            stateDelivery: .contextAndMessage, releasesOutstandingOnRetirement: false),
            encode: { preview, profile in
                await Task.detached(priority: .userInitiated) {
                    Self.encodePreview(preview, profile: profile)
                }.value
            })
        relay.onAdmittedCommand = { [weak self] action, admission in
            let fallback = WatchCommandResult(accepted: false, isRecording: false, error: "unavailable")
            switch action {
            case .toggleRecord:
                return self?.onAdmittedToggleRecord?(admission) ?? self?.onToggleRecord?() ?? fallback
            case .capture:
                return self?.onAdmittedCapture?(admission) ?? self?.onCapture?() ?? fallback
            case .resume: return fallback
            }
        }
    }
    public var isReady: Bool { relay.isReady }
    public var hasCompanion: Bool { relay.hasCompanion }
    public func activate() { relay.activate() }
    public func ingestState(_ state: WatchRelayState) { relay.ingestState(state) }
    public func retireSource() { relay.retireSource() }
    public func close() { relay.close() }
    public func ingestPreview(
        _ image: CIImage, source: CVPixelBuffer? = nil, unmanaged: Bool = false,
        mirrored: Bool = false, flippedVertically: Bool = false, timecode: String,
        isRecording: Bool
    ) {
        relay.ingestPreview(WatchNativePreview(image: image, source: source,
            unmanaged: unmanaged, mirrored: mirrored, flippedVertically: flippedVertically,
            timecode: timecode, isRecording: isRecording))
    }
    nonisolated private static func encodePreview(
        _ preview: WatchNativePreview, profile: RelayPreviewProfile
    ) -> WatchRelayFrame? {
        let width = CGFloat(profile.maximumWidth)
        let quality = CGFloat(profile.qualityPercent) / 100
        let bytes: Data?
        if preview.unmanaged {
            bytes = thumbnailData(from: preview.image, unmanaged: true, mirrored: preview.mirrored,
                flippedVertically: preview.flippedVertically, maxWidth: width, quality: quality)
        } else if let source = preview.source {
            bytes = thumbnailData(from: source, mirrored: preview.mirrored,
                flippedVertically: preview.flippedVertically, maxWidth: width, quality: quality)
        } else {
            bytes = thumbnailData(from: preview.image, unmanaged: false, mirrored: preview.mirrored,
                flippedVertically: preview.flippedVertically, maxWidth: width, quality: quality)
        }
        guard let bytes else { return nil }
        return WatchRelayFrame(jpeg: bytes, timecode: preview.timecode, isRecording: preview.isRecording)
    }
        nonisolated public static func encodedFrameData(_ image: UIImage, quality: CGFloat) -> Data? {
            image.jpegData(compressionQuality: quality)
        }

        /// Identity path. Matches `AVSampleBufferDisplayLayer` better than a
        /// DeviceRGB CI bake (that bake was a visible Rec.709 contrast shift).
        nonisolated public static func thumbnailData(
            from buffer: CVPixelBuffer, mirrored: Bool = false, flippedVertically: Bool = false,
            maxWidth: CGFloat, quality: CGFloat
        ) -> Data? {
            var imageOut: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(
                downscaled(buffer, maxWidth: maxWidth) ?? buffer, options: nil,
                imageOut: &imageOut)
            guard status == noErr, let cg = imageOut,
                let jpeg = encodedFrameData(
                    scaledImage(
                        cg, mirrored: mirrored, flippedVertically: flippedVertically,
                        maxWidth: maxWidth), quality: quality)
            else {
                return thumbnailData(
                    from: CIImage(cvPixelBuffer: buffer), unmanaged: false, mirrored: mirrored,
                    flippedVertically: flippedVertically, maxWidth: maxWidth, quality: quality)
            }
            return jpeg
        }

        nonisolated private static let scaler = OSAllocatedUnfairLock<VTPixelTransferSession?>(
            initialState: nil)

        /// Hardware scale in the source's own YUV format and colour tags, so the
        /// unchanged VT RGB conversion runs on the wrist-sized buffer instead of
        /// the full live picture. `nil` keeps the full-size path.
        nonisolated public static func downscaled(_ buffer: CVPixelBuffer, maxWidth: CGFloat)
            -> CVPixelBuffer?
        {
            let width = CGFloat(CVPixelBufferGetWidth(buffer))
            let height = CGFloat(CVPixelBufferGetHeight(buffer))
            guard width > maxWidth, height > 1 else { return nil }
            // Even dimensions for 4:2:0.
            let w = Int((maxWidth / 2).rounded(.down)) * 2
            let h = Int((height * maxWidth / width / 2).rounded()) * 2
            var out: CVPixelBuffer?
            guard w >= 2, h >= 2,
                CVPixelBufferCreate(
                    kCFAllocatorDefault, w, h, CVPixelBufferGetPixelFormatType(buffer),
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &out)
                    == kCVReturnSuccess, let out
            else { return nil }
            let status = scaler.withLock { session -> OSStatus in
                if session == nil {
                    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session)
                }
                guard let session else { return kVTAllocationFailedErr }
                return VTPixelTransferSessionTransferImage(session, from: buffer, to: out)
            }
            guard status == noErr else { return nil }
            CVBufferPropagateAttachments(buffer, out)
            return out
        }

        nonisolated public static func thumbnailData(
            from image: CIImage, unmanaged: Bool = false, mirrored: Bool = false,
            flippedVertically: Bool = false, maxWidth: CGFloat, quality: CGFloat
        ) -> Data? {
            let extent = image.extent
            guard extent.width > 1, extent.height > 1 else { return nil }
            let scale = min(1, maxWidth / extent.width)
            let oriented =
                mirrored || flippedVertically
                ? image.transformed(
                    by: CGAffineTransform(
                        a: mirrored ? -1 : 1, b: 0, c: 0, d: flippedVertically ? -1 : 1,
                        tx: mirrored ? extent.minX + extent.maxX : 0,
                        ty: flippedVertically ? extent.minY + extent.maxY : 0))
                : image
            let scaled = oriented.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let target = scaled.extent.integral
            guard target.width > 1, target.height > 1 else { return nil }
            let cg: CGImage?
            if unmanaged {
                cg = lutContext.createCGImage(scaled, from: target)
            } else {
                let srgb =
                    CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
                cg = displayContext.createCGImage(
                    scaled, from: target, format: .RGBA8, colorSpace: srgb)
            }
            guard let cg else { return nil }
            return encodedFrameData(UIImage(cgImage: cg), quality: quality)
        }

        nonisolated private static func scaledImage(
            _ cg: CGImage, mirrored: Bool, flippedVertically: Bool, maxWidth: CGFloat
        ) -> UIImage {
            let width = CGFloat(cg.width)
            let height = CGFloat(cg.height)
            let scale = min(1, maxWidth / max(width, 1))
            let size = CGSize(
                width: max(1, (width * scale).rounded()),
                height: max(1, (height * scale).rounded()))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                if mirrored {
                    renderer.cgContext.translateBy(x: size.width, y: 0)
                    renderer.cgContext.scaleBy(x: -1, y: 1)
                }
                if flippedVertically {
                    renderer.cgContext.translateBy(x: 0, y: size.height)
                    renderer.cgContext.scaleBy(x: 1, y: -1)
                }
                UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
            }
        }
}
#endif
#endif
