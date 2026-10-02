#if os(iOS) && canImport(AVFoundation)
    import AVFoundation
    import Foundation
    import OpenCineCore
    import UIKit
    import os

    /// What the HDMI capture path is currently doing. Operator copy for each state stays in the app.
    public enum UVCVideoSourceState: Equatable, Sendable {
        /// This device cannot host a capture device at all. iPadOS exposes UVC devices; iOS does not.
        case unsupportedDevice
        /// The operator has not granted camera access, or refused it.
        case permissionDenied
        /// Supported and permitted, but nothing is plugged in.
        case waitingForDevice
        /// A device is attached and the session is coming up.
        case starting
        /// Frames are arriving. Carries the device's own product name and the format actually
        /// selected: the resolution and rate are the first thing to check when the picture looks
        /// worse than expected, and they should not need a console to read.
        case streaming(deviceName: String, format: String?)
        case failed(reason: String)

        public var isStreaming: Bool {
            if case .streaming = self { return true }
            return false
        }
    }

    /// A native capture source: an HDMI signal digitised by an attached USB Video Class device
    /// (plan 3.2: capture devices participate without a manufacturer package).
    ///
    /// ## Why this is native rather than a USB driver
    ///
    /// `AVCaptureDevice.DeviceType.external` *is* UVC on iPadOS ("On iPad, external devices are those
    /// that conform to the UVC specification", `AVCaptureDevice.h`), available from iOS 17. No
    /// entitlement is required; only visionOS before 3.0 needed one. So the whole capture path is
    /// AVFoundation, and the dongle's vendor and chipset never matter.
    ///
    /// ## Frames
    ///
    /// Each captured `CVPixelBuffer` (BGRA) is lent to the consumer as a `DecodedFrameLease`
    /// stamped with this source's stream and generation. The generation advances whenever the
    /// capture device goes away or changes, so a frame buffered from the previous device is stale.
    /// The source used to render every frame to a `UIImage` on the capture queue; that render (an
    /// app whose consumers need a CGImage-backed bitmap) is now the app's, done only for the frames
    /// the newest-wins stream actually hands over.
    public final class UVCVideoSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
        @unchecked Sendable
    {
        /// Whether this hardware can host a UVC capture device at all.
        ///
        /// iPad only, in every configuration, and deliberately checked by idiom rather than by
        /// probing for devices, so a connect flow can explain the limitation on an iPhone instead
        /// of showing a path that will never find anything. The Simulator reports `.pad` on an
        /// iPad simulator but never enumerates a device, which lands on `waitingForDevice`.
        @MainActor public static var isSupportedHardware: Bool { isDocumentedHardware }

        /// Whether Apple documents UVC support on this hardware. Kept separate from
        /// `isSupportedHardware` so a build that lets a phone try can still explain why it found
        /// nothing.
        @MainActor public static var isDocumentedHardware: Bool {
            UIDevice.current.userInterfaceIdiom == .pad
        }

        /// Delivered frames, newest-wins.
        ///
        /// A stream rather than a callback so the consumer is a single serial loop instead of one
        /// task per frame, which at 60 fps would both churn tasks and let frames overtake each
        /// other on the way to the screen. `bufferingNewest(1)` is the monitor's rule stated as a
        /// policy: show the latest frame, drop what it replaced.
        public let frames: AsyncStream<DecodedFrameLease>
        /// Stamps `frames`; advances when the capture device goes away or changes.
        public let fence: DecodedFrameFence
        private let framesContinuation: AsyncStream<DecodedFrameLease>.Continuation
        /// Called on the main actor whenever `state` changes.
        private let onStateChange: @MainActor (UVCVideoSourceState) -> Void
        private let log: Logger

        private let session = AVCaptureSession()
        /// Serial queue owning session mutation and sample delivery. `startRunning` blocks, so it
        /// must never be the main thread.
        private let captureQueue: DispatchQueue
        private var currentDevice: AVCaptureDevice?
        private var isRunning = false

        /// `queueLabel` and `logSubsystem` name the capture queue and log category after the app.
        public init(
            stream: StreamID = StreamID(), queueLabel: String, logSubsystem: String,
            onStateChange: @escaping @MainActor (UVCVideoSourceState) -> Void
        ) {
            (self.frames, self.framesContinuation) = AsyncStream.makeStream(
                of: DecodedFrameLease.self, bufferingPolicy: .bufferingNewest(1))
            self.fence = DecodedFrameFence(stream: stream)
            self.onStateChange = onStateChange
            self.log = Logger(subsystem: logSubsystem, category: "uvc-capture")
            self.captureQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
            super.init()
        }

        // MARK: - Lifecycle

        /// Requests permission if needed, then brings the session up around whatever is attached.
        @MainActor
        public func start() async {
            guard Self.isSupportedHardware else {
                onStateChange(.unsupportedDevice)
                return
            }
            guard await Self.ensureCameraAccess() else {
                onStateChange(.permissionDenied)
                return
            }
            observeDeviceChanges()
            Self.logDiscoverableVideoDevices()
            onStateChange(.starting)
            captureQueue.async { [weak self] in self?.configureAndRun() }
        }

        /// Debug-only census of every video device the system will admit to.
        ///
        /// The question is not really "does `.external` return something" but whether the dongle
        /// shows up *at all*, possibly under another type, the way Mac Catalyst reports external
        /// cameras as `builtInWideAngleCamera` unless an Info.plist key opts in. "Found nothing"
        /// and "found it, filed differently" are very different answers.
        private static func logDiscoverableVideoDevices() {
            #if DEBUG
                let types: [AVCaptureDevice.DeviceType] = [
                    .external, .builtInWideAngleCamera, .builtInTelephotoCamera,
                    .builtInUltraWideCamera, .builtInDualCamera, .builtInDualWideCamera,
                    .builtInTripleCamera, .continuityCamera,
                ]
                let devices = AVCaptureDevice.DiscoverySession(
                    deviceTypes: types, mediaType: .video, position: .unspecified
                ).devices
                let census =
                    devices
                    .map { "\($0.localizedName) [\($0.deviceType.rawValue)]" }
                    .joined(separator: ", ")
                print("UVC census (\(devices.count)): \(census.isEmpty ? "none" : census)")
            #endif
        }

        /// Tears the session down. Safe to call more than once, and safe to call before `start`.
        @MainActor
        public func stop() {
            NotificationCenter.default.removeObserver(self)
            // Ends the consumer's `for await`, so a stopped source can never keep a loop alive.
            framesContinuation.finish()
            fence.advance()
            captureQueue.async { [weak self] in
                guard let self else { return }
                if self.session.isRunning { self.session.stopRunning() }
                self.isRunning = false
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                self.currentDevice = nil
            }
        }

        private static func ensureCameraAccess() async -> Bool {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: return true
            case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
            default: return false
            }
        }

        /// A capture dongle is hot-pluggable and is very often plugged in *after* the operator has
        /// chosen HDMI, so attach/detach has to re-drive the session rather than being read once.
        @MainActor
        private func observeDeviceChanges() {
            let center = NotificationCenter.default
            center.removeObserver(self)
            for name in [
                AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
            ] {
                center.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in
                    guard let self else { return }
                    self.captureQueue.async { self.configureAndRun() }
                }
            }
        }

        // MARK: - Session configuration (capture queue only)

        private func configureAndRun() {
            dispatchPrecondition(condition: .onQueue(captureQueue))
            guard let device = Self.attachedCaptureDevice() else {
                if isRunning || currentDevice != nil {
                    if session.isRunning { session.stopRunning() }
                    session.inputs.forEach(session.removeInput)
                    session.outputs.forEach(session.removeOutput)
                    isRunning = false
                    currentDevice = nil
                    fence.advance()
                }
                publish(.waitingForDevice)
                return
            }
            // Already streaming from this exact device: an unrelated attach event, so leave the
            // running session alone rather than restarting it and dropping frames.
            if isRunning, currentDevice?.uniqueID == device.uniqueID { return }
            if currentDevice != nil { fence.advance() }

            let selectedFormat: String?
            do {
                selectedFormat = try configure(for: device)
            } catch {
                publish(
                    .failed(
                        reason: "The capture device couldn't be opened: \(error.localizedDescription)"
                    ))
                return
            }
            if !session.isRunning { session.startRunning() }
            isRunning = session.isRunning
            currentDevice = device
            publish(
                isRunning
                    ? .streaming(deviceName: device.localizedName, format: selectedFormat)
                    : .failed(reason: "The capture session didn't start."))
        }

        /// Returns a human-readable description of the format actually selected, if one was.
        @discardableResult
        private func configure(for device: AVCaptureDevice) throws -> String? {
            session.beginConfiguration()
            defer { session.commitConfiguration() }

            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            // The capture device's own `activeFormat` decides the resolution, not a preset ladder:
            // presets describe built-in cameras and would quietly downscale an HDMI signal.
            session.sessionPreset = .inputPriority

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw UVCError.cannotAddInput
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            // BGRA so a CIImage to CGImage render is a straight copy rather than a colour conversion.
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            // A monitor shows the newest frame or it is not a monitor: never queue behind a slow bake.
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: captureQueue)
            guard session.canAddOutput(output) else {
                throw UVCError.cannotAddOutput
            }
            session.addOutput(output)

            // AVFoundation will happily crop a capture connection on our behalf, and both mechanisms
            // are silent: video stabilization reserves a margin (~10%) to swing the frame around in,
            // and the scale-and-crop factor is a plain zoom. Neither has any business on a monitor
            // feed: the operator is judging framing, so the one guarantee that matters is that what
            // the camera sent is what reaches the screen. Set both explicitly rather than trusting
            // the defaults for an external device.
            if let connection = output.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
                connection.videoScaleAndCropFactor = 1
            }

            return selectBestFormat(on: device)
        }

        /// Below this a format is a slideshow, not a monitor feed.
        private static let minimumUsableFrameRate = 24.0

        /// Frame heights to prefer when the incoming signal's own resolution is unknowable.
        ///
        /// AVFoundation exposes what the device can send over USB but never what it locked on HDMI,
        /// and capturing ABOVE the input resolution is pure upscale: it spends bandwidth on pixels
        /// that carry no detail the device ever received, and on a compressed format it takes bits
        /// away from the pixels that do. A device's largest mode is therefore only its best mode
        /// when the input is at least that large: the UGREEN's 2560x1440 is a genuine mode of its
        /// (spec: capture up to 2K@30) yet the wrong choice while the camera feeds it 1080p.
        ///
        /// Preferring broadcast standards lands on the input's own resolution in the common cases,
        /// and on this class of device the 1080p mode is additionally offered at twice the frame
        /// rate of the largest one. It stays a heuristic: the honest answer for an operator who
        /// knows their own signal chain is to pick the format explicitly. [verify-on-HW]
        private static let preferredCaptureHeights = [2160, 1080, 720]

        /// True for a 16:9 mode: the shape a camera's HDMI output actually is, as opposed to the
        /// DCI (256:135) modes a 4K-capable link also advertises.
        public static func isBroadcastShaped(_ dimensions: CMVideoDimensions) -> Bool {
            guard dimensions.width > 0, dimensions.height > 0 else { return false }
            let aspect = Double(dimensions.width) / Double(dimensions.height)
            return abs(aspect / (16.0 / 9.0) - 1) <= 0.02
        }

        /// Picks the best format the device can actually feed, and returns a description of it.
        ///
        /// Three filters in order, because each one alone picks wrongly on real hardware: usable
        /// frame rate (a dongle advertises the resolutions it accepts on HDMI, not the ones it can
        /// push down USB), then a natively-produced resolution (it also advertises sizes its scaler
        /// invents), then the largest of what survives. Devices list the same resolution twice
        /// (MJPEG and uncompressed), so the final rate tiebreak lands on whichever encoding the
        /// device can sustain.
        @discardableResult
        private func selectBestFormat(on device: AVCaptureDevice) -> String? {
            let ranked = device.formats.map {
                format -> (
                    format: AVCaptureDevice.Format, pixels: Int, fps: Double,
                    dimensions: CMVideoDimensions
                ) in
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let fps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return (format, Int(dimensions.width) * Int(dimensions.height), fps, dimensions)
            }
            #if DEBUG
                let census =
                    ranked
                    .map { "\($0.dimensions.width)x\($0.dimensions.height)@\(Int($0.fps.rounded()))" }
                    .joined(separator: ", ")
                print("UVC formats (\(ranked.count)): \(census)")
            #endif

            // MOTION BEFORE PIXELS. Ranking on resolution alone picks whatever descriptor the
            // device advertises largest, and a capture dongle advertises the resolutions it will
            // *accept on HDMI*, not the ones it can push down USB. Selecting one of those is a good
            // way to end up holding a format the hardware never feeds, which presents as a dead or
            // "no signal" stream rather than an error. Take the largest format that can still carry
            // motion, and only fall back to the unfiltered list if the device offers nothing at
            // rate at all.
            let usable = ranked.filter { $0.fps >= Self.minimumUsableFrameRate }
            let candidates = usable.isEmpty ? ranked : usable
            // Then prefer a resolution the incoming signal plausibly IS, over the largest the
            // device can synthesise (see `preferredCaptureHeights`). Falls through to the full list
            // for anything unusual, so a device offering only non-standard sizes still streams.
            let preferred = candidates.filter {
                Self.preferredCaptureHeights.contains(Int($0.dimensions.height))
            }
            let pool = preferred.isEmpty ? candidates : preferred
            // Then prefer a mode shaped like the signal. A camera's HDMI output is 16:9, while a
            // DCI 4096x2160 mode is 256:135: asking a link for that mode makes it fit a 16:9 signal
            // into a shape the signal never had, and the cheap ones resolve that by cropping rather
            // than padding. Ranking on pixels alone picks DCI over UHD (8.8M beats 8.3M), which is
            // how a 4K60-capable link started cropping a feed the previous one showed whole
            // (issue #115 of the app it came from). DCI stays in the pool for a signal that really is 4096 wide.
            let signalShaped = pool.filter { Self.isBroadcastShaped($0.dimensions) }
            let shaped = signalShaped.isEmpty ? pool : signalShaped
            guard
                let best = shaped.max(by: { lhs, rhs in
                    lhs.pixels == rhs.pixels ? lhs.fps < rhs.fps : lhs.pixels < rhs.pixels
                })
            else { return nil }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.activeFormat = best.format
            } catch {
                // A device that refuses configuration still streams in its default format, which
                // is a worse picture but a working one: not worth failing the whole session over.
                return nil
            }
            return "\(best.dimensions.width)×\(best.dimensions.height) @\(Int(best.fps.rounded()))"
        }

        /// The attached capture device's product name, without opening a session.
        ///
        /// Lets a connect flow say whether the dongle is there before committing to a capture
        /// session, which on this path is the operator's whole question.
        @MainActor public static var attachedDeviceName: String? {
            guard isSupportedHardware else { return nil }
            return attachedCaptureDevice()?.localizedName
        }

        private static func attachedCaptureDevice() -> AVCaptureDevice? {
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video, position: .unspecified
            ).devices.first
        }

        private func publish(_ state: UVCVideoSourceState) {
            Task { @MainActor [onStateChange] in onStateChange(state) }
        }

        private enum UVCError: LocalizedError {
            case cannotAddInput
            case cannotAddOutput

            var errorDescription: String? {
                switch self {
                case .cannotAddInput: "the session refused the capture device"
                case .cannotAddOutput: "the session refused the video output"
                }
            }
        }

        // MARK: - Signal colorimetry

        /// What the capture chain CLAIMS the signal is, read from the first frame's attachments.
        /// Two distinct field reports hide in one "the HDMI picture looks wrong": a camera sending
        /// its recording gamma over HDMI (log/HLG: flat or green-tinted until the monitoring LUT is
        /// applied; fixed on the CAMERA's HDMI output setting), and a dongle mis-tagging matrix or
        /// range (our side; would need an override this readout is the evidence for). Without the
        /// readout, both look like "the app shifted my colors".
        public var onSignalColorimetry: (@MainActor (String) -> Void)?
        private var reportedColorimetry = false

        private func reportSignalColorimetryOnce(of pixelBuffer: CVPixelBuffer) {
            guard !reportedColorimetry else { return }
            reportedColorimetry = true
            func tag(_ key: CFString) -> String {
                guard let value = CVBufferCopyAttachment(pixelBuffer, key, nil) as? String else {
                    return "untagged"
                }
                return Self.shortColorimetryName(value)
            }
            let summary =
                "\(tag(kCVImageBufferColorPrimariesKey))/\(tag(kCVImageBufferTransferFunctionKey))"
                + "/\(tag(kCVImageBufferYCbCrMatrixKey))"
            log.info("UVC signal colorimetry: \(summary, privacy: .public)")
            Task { @MainActor [onSignalColorimetry] in onSignalColorimetry?(summary) }
        }

        /// The CoreVideo constants' raw values, shortened to what an operator can read; anything
        /// unrecognised passes through raw (still evidence).
        static func shortColorimetryName(_ raw: String) -> String {
            switch raw {
            case "ITU_R_709_2": "709"
            case "ITU_R_601_4": "601"
            case "ITU_R_2020": "2020"
            case "ITU_R_2100_HLG": "HLG"
            case "SMPTE_ST_2084_PQ", "SMPTE_ST_2084": "PQ"
            case "sRGB", "IEC_sRGB": "sRGB"
            default: raw
            }
        }

        // MARK: - Frame delivery

        public func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            reportSignalColorimetryOnce(of: pixelBuffer)
            // The capture clock is the host clock; nanoseconds of the frame's presentation time.
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timeNs = pts.isNumeric ? Int64(CMTimeGetSeconds(pts) * 1_000_000_000) : 0
            framesContinuation.yield(fence.lease(pixelBuffer, timeNs: timeNs))
        }
    }
#endif
