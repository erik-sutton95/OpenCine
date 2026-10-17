#if canImport(AVFoundation) && canImport(CoreVideo)
import AVFoundation
import CoreVideo
import Foundation
import OpenCineMedia
import os

/// Host-selected local footage and diagnostics; no app namespace belongs to the native reader.
public struct MonitorSimulatorVideoConfiguration: Sendable {
    public var clipURL: @Sendable () -> URL?
    public var transfer: MonitorTransfer
    public var queueLabel: String
    public var logSubsystem: String
    public var missingClipMessage: String
    public var startedMessage: String

    public init(clipURL: @escaping @Sendable () -> URL?, transfer: MonitorTransfer,
        queueLabel: String = "opencine.sim-live", logSubsystem: String = "com.opencapture.opencine",
        missingClipMessage: String = "Simulator live feed clip not configured",
        startedMessage: String = "Simulator clip looping through the native decoder") {
        self.clipURL = clipURL; self.transfer = transfer
        self.queueLabel = queueLabel; self.logSubsystem = logSubsystem
        self.missingClipMessage = missingClipMessage; self.startedMessage = startedMessage
    }
}

/// Serial AVAssetReader input with the retained 25 Hz, video-range source policy.
final class MonitorSimulatorVideoFeed: @unchecked Sendable {
    private let configuration: MonitorSimulatorVideoConfiguration
    private let queue: DispatchQueue
    private let log: Logger

    init(configuration: MonitorSimulatorVideoConfiguration) {
        self.configuration = configuration
        queue = DispatchQueue(label: configuration.queueLabel, qos: .userInitiated)
        log = Logger(subsystem: configuration.logSubsystem, category: "sim-live")
    }
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var timer: DispatchSourceTimer?
    private var sink: (@Sendable (CVPixelBuffer) -> Void)?
    private var missingLogged = false
    private var running = false
    private var loggedFirst = false

    func start(sink: @escaping @Sendable (CVPixelBuffer) -> Void) {
        queue.async { [self] in
            if running {
                self.sink = sink
                return
            }
            begin(sink: sink)
        }
    }

    func stop() {
        queue.async { [self] in teardown() }
    }

    private func begin(sink: @escaping @Sendable (CVPixelBuffer) -> Void) {
        teardown()
        self.sink = sink
        guard let url = configuration.clipURL(), FileManager.default.fileExists(atPath: url.path) else {
            if !missingLogged {
                missingLogged = true
                log.warning(
                    "\(self.configuration.missingClipMessage, privacy: .public)"
                )
            }
            return
        }
        guard openReader() else { return }
        running = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.04, repeating: 1.0 / 25.0)
        timer.setEventHandler { [weak self] in self?.pull() }
        timer.resume()
        self.timer = timer
        log.info("\(self.configuration.startedMessage, privacy: .public)")
    }

    @discardableResult
    private func openReader() -> Bool {
        reader?.cancelReading()
        reader = nil
        output = nil
        guard let url = configuration.clipURL() else { return false }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            log.error("Simulator clip has no video track")
            return false
        }
        do {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                log.error(
                    "AVAssetReader failed to start: \(reader.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
                return false
            }
            self.reader = reader
            self.output = output
            return true
        } catch {
            log.error("AVAssetReader: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func pull() {
        guard let sink else { return }
        if reader?.status == .completed || output == nil {
            _ = openReader()
        }
        guard let output,
            let sample = output.copyNextSampleBuffer(),
            let buffer = CMSampleBufferGetImageBuffer(sample)
        else { return }
        if !loggedFirst {
            loggedFirst = true
            let format = CVPixelBufferGetPixelFormatType(buffer)
            let chars = [
                UInt8((format >> 24) & 0xFF), UInt8((format >> 16) & 0xFF),
                UInt8((format >> 8) & 0xFF), UInt8(format & 0xFF),
            ]
            let fourCC = String(bytes: chars, encoding: .ascii) ?? String(format)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let baseNil = CVPixelBufferGetBaseAddress(buffer) == nil
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            log.info(
                "first sim frame \(fourCC, privacy: .public) \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) planes=\(CVPixelBufferGetPlaneCount(buffer)) baseNil=\(baseNil)"
            )
        }
        sink(buffer)
    }

    private func teardown() {
        timer?.cancel()
        timer = nil
        reader?.cancelReading()
        reader = nil
        output = nil
        sink = nil
        running = false
        loggedFirst = false
    }
}
#endif
