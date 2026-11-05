import CoreGraphics
import CoreMedia
import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import OpenCineDesktopKit
import OpenCineVirtualCamera
import os

private let log = Logger(
    subsystem: "com.opencapture.opencine.camera", category: "delivery")
private let signposter = OSSignposter(logger: log)

/// One serial provider queue owns all stream state and the sole outstanding sink request.
final class OpenCineCameraProvider: NSObject, CMIOExtensionProviderSource {
    /// Where the dock writes which module owns which slot. The driver runs as a system user, so
    /// this is a shared path readable through the extension's sandbox exception, not a container.
    static let slotTableURL = URL(fileURLWithPath: "/Users/Shared/OpenCine/virtual-camera-slots.json")
    private(set) var provider: CMIOExtensionProvider!
    /// Devices by slot number. A device is added once and stays while the driver runs, so receiving
    /// apps never see an input vanish mid-session.
    private var cameras: [Int: CameraDevice] = [:]
    private var watcher: DispatchSourceTimer?
    private let queue = DispatchQueue(
        label: "com.opencapture.opencine.camera.delivery", qos: .userInteractive,
        autoreleaseFrequency: .workItem)

    override init() {
        super.init()
    }

    convenience init(configured: Bool = true) throws {
        self.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: queue)
        queue.sync { publishAssignedSlots() }
        let watcher = DispatchSource.makeTimerSource(queue: queue)
        watcher.schedule(deadline: .now() + 2, repeating: 2)
        watcher.setEventHandler { [weak self] in self?.publishAssignedSlots() }
        self.watcher = watcher
        watcher.resume()
    }

    /// Adds a device for every assignment not yet published. An unreadable table changes nothing.
    private func publishAssignedSlots() {
        guard let table = try? Data(contentsOf: Self.slotTableURL),
            let decoded = try? JSONDecoder().decode(VirtualCameraSlotTable.self, from: table),
            decoded.version == VirtualCameraSlotTable.currentVersion
        else { return }
        for assignment in decoded.assignments where cameras[assignment.slot] == nil {
            guard let slot = VirtualCameraSlot(number: assignment.slot) else { continue }
            do {
                let camera = try CameraDevice(
                    slot: slot, displayName: assignment.displayName, queue: queue)
                try provider.addDevice(camera.device)
                cameras[assignment.slot] = camera
                log.notice("Published slot \(slot.number) as \(assignment.displayName, privacy: .public)")
            } catch {
                log.error("Could not publish slot \(slot.number): \(error, privacy: .public)")
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerName, .providerManufacturer] }
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties
    {
        let value = CMIOExtensionProviderProperties(dictionary: [:])
        value.name = "OpenCine"
        value.manufacturer = "OpenCapture"
        return value
    }
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {
        for camera in cameras.values { camera.disconnected(client) }
    }
}

private enum CameraError: Error {
    case allocation(OSStatus)
    case unsupportedFormat, producerUnavailable
}

/// A stable device with one public source and one authenticated producer sink.
private final class CameraDevice: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStream!
    private var sink: CameraStream!
    private let queue: DispatchQueue
    private let policy = FramePolicy<CMSampleBuffer>()
    private let formatDescription: CMFormatDescription
    private let offSlate: CVPixelBuffer
    private let waitingSlate: CVPixelBuffer
    private var producer: CMIOExtensionClient?
    private var producerEpoch: UInt64 = 0
    private var sourceStarts = 0
    private var sinkStarted = false
    private var consumeOutstanding = false
    private var timer: DispatchSourceTimer?
    private var cadence = FrameCadence(framesPerSecond: 30)
    private var discontinuity: CMIOExtensionStream.DiscontinuityFlags = [.time]
    private var lastPictureKind: Int?
    private(set) var underruns = 0
    private var delivered: UInt64 = 0
    private var malformed: UInt64 = 0
    private var lastDiagnostics: UInt64 = 0

    private let slot: VirtualCameraSlot
    private let displayName: String

    init(slot: VirtualCameraSlot, displayName: String, queue: DispatchQueue) throws {
        self.slot = slot
        self.displayName = displayName
        self.queue = queue
        formatDescription = try CMFormatDescription(
            videoCodecType: CMFormatDescription.MediaSubType(rawValue: kCVPixelFormatType_32BGRA),
            width: 1920, height: 1080)
        offSlate = try Self.makeSlate(title: displayName, message: "Camera not connected")
        waitingSlate = try Self.makeSlate(title: displayName, message: "Waiting for picture")
        super.init()
        device = CMIOExtensionDevice(
            localizedName: displayName, deviceID: slot.deviceUUID,
            legacyDeviceID: slot.legacyDeviceID, source: self)
        source = CameraStream(
            owner: self, direction: .source, name: displayName, id: slot.sourceStreamUUID,
            description: formatDescription)
        sink = CameraStream(
            owner: self, direction: .sink, name: slot.sinkStreamName, id: slot.sinkStreamUUID,
            description: formatDescription)
        try device.addStream(source.stream)
        try device.addStream(sink.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let value = CMIOExtensionDeviceProperties(dictionary: [:])
        value.transportType = 0x7669_7274
        value.model = displayName
        return value
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func authorize(_ client: CMIOExtensionClient) -> Bool {
        let signingID = client.signingID ?? "missing"
        guard client.pid > 0, ProducerAdmission.accepts(signingHint: client.signingID) else {
            log.error(
                "Producer rejected: explicit signing hint=\(signingID, privacy: .public) pid=\(client.pid)"
            )
            return false
        }
        guard let epoch = policy.claim(client.clientID) else {
            log.error("Producer rejected: another owner holds sink, pid=\(client.pid)")
            return false
        }
        log.info(
            "Producer authorized by CMIO platform: signingID=\(signingID, privacy: .public) pid=\(client.pid)"
        )
        producer = client
        producerEpoch = epoch
        discontinuity.insert(.time)
        return true
    }

    func start(_ direction: CMIOExtensionStream.Direction) throws {
        if direction == .source {
            sourceStarts += 1
        } else {
            guard producer != nil else { throw CameraError.producerUnavailable }
            sinkStarted = true
        }
        guard timer == nil else { return }
        cadence.reset(framesPerSecond: source.framesPerSecond)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now(), repeating: .nanoseconds(8_333_333), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    func stop(_ direction: CMIOExtensionStream.Direction) {
        if direction == .source {
            sourceStarts = max(0, sourceStarts - 1)
        } else {
            retireProducer()
        }
        stopTimerIfIdle()
    }

    func disconnected(_ client: CMIOExtensionClient) {
        guard producer?.clientID == client.clientID else { return }
        retireProducer()
        stopTimerIfIdle()
    }

    private func retireProducer() {
        if let producer { policy.retire(producer.clientID) }
        producer = nil
        discontinuity.insert(.time)
        sinkStarted = false
        // An already outstanding framework callback is fenced by the retired epoch.
    }

    private func stopTimerIfIdle() {
        guard sourceStarts == 0, !sinkStarted else { return }
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if sinkStarted, !consumeOutstanding { consume() }
        let now = Self.hostNow()
        let previousSkipped = cadence.skipped
        if sourceStarts > 0, cadence.isDue(now: now) {
            if cadence.skipped > previousSkipped { discontinuity.insert(.sampleDropped) }
            publish(now: now, duration: source.frameDuration)
        }
        if now > lastDiagnostics + 10_000_000_000 {
            lastDiagnostics = now
            log.info(
                "delivery=\(self.delivered) replaced=\(self.policy.replaced) repeats=\(self.policy.repeats) rejected=\(self.policy.rejected) malformed=\(self.malformed) skipped=\(self.cadence.skipped) underruns=\(self.underruns)"
            )
        }
    }

    private func consume() {
        guard let client = producer else { return }
        let epoch = producerEpoch
        let producerID = client.clientID
        consumeOutstanding = true
        sink.stream.consumeSampleBuffer(from: client) {
            [weak self] sample, sequence, _, hasMore, error in
            guard let self else { return }
            // The box retains the framework buffer until our serial owner admits or discards it.
            let result = SinkResult(
                sample: sample, sequence: sequence, hasMore: hasMore, failed: error != nil)
            self.queue.async { [weak self] in
                guard let self else { return }
                self.consumeOutstanding = false
                guard self.producer?.clientID == producerID, self.producerEpoch == epoch,
                    self.sinkStarted
                else { return }
                let now = Self.hostNow()
                if let sample = result.sample, !result.failed {
                    signposter.emitEvent("Camera sink receive")
                    self.admit(sample, producer: producerID, epoch: epoch, now: now)
                } else {
                    self.underruns &+= 1
                }
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(
                        sequenceNumber: result.sequence, hostTimeInNanoseconds: now))
                if result.hasMore { self.consume() }
            }
        }
    }

    private func admit(_ sample: CMSampleBuffer, producer: UUID, epoch: UInt64, now: UInt64) {
        guard CMSampleBufferDataIsReady(sample), let image = CMSampleBufferGetImageBuffer(sample),
            CVPixelBufferGetWidth(image) == 1920, CVPixelBufferGetHeight(image) == 1080,
            CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
            CMSampleBufferGetNumSamples(sample) == 1
        else {
            malformed &+= 1
            return
        }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric, time.epoch == 0, time.seconds >= 0,
            time.seconds < Double(UInt64.max) / 1_000_000_000
        else {
            malformed &+= 1
            return
        }
        policy.offer(
            sample, producer: producer, generation: epoch,
            timestamp: UInt64(time.seconds * 1_000_000_000), now: now)
    }

    private func publish(now: UInt64, duration: CMTime) {
        let image: CVPixelBuffer
        let pictureKind: Int
        let original: CMSampleBuffer?
        let captureHostTime: UInt64
        switch policy.output(now: now) {
        case .frame(let sample, _):
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            image = buffer
            original = sample
            captureHostTime = UInt64(
                CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1_000_000_000)
            pictureKind = 0
        case .slate(.feedOff):
            image = offSlate
            original = nil
            captureHostTime = now
            pictureKind = 1
        case .slate(.noFeed):
            image = waitingSlate
            original = nil
            captureHostTime = now
            pictureKind = 2
        }
        if lastPictureKind != pictureKind { discontinuity.insert(.time) }
        lastPictureKind = pictureKind
        let timestamp = policy.outputTimestamp(now: now)
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        if let original {
            output = try? SampleEnvelope.retime(
                original, outputTime: timing.presentationTimeStamp, duration: duration)
        } else {
            let status = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                sampleTiming: &timing, sampleBufferOut: &output)
            guard status == noErr else {
                malformed &+= 1
                return
            }
        }
        guard let output else {
            malformed &+= 1
            return
        }
        signposter.emitEvent("Camera delivery")
        source.stream.send(
            output, discontinuity: discontinuity, hostTimeInNanoseconds: captureHostTime)
        discontinuity = []
        delivered &+= 1
    }

    func formatChanged() {
        cadence.reset(framesPerSecond: source.framesPerSecond)
        discontinuity.insert(.time)
    }

    private static func hostNow() -> UInt64 {
        let value = CMClockGetTime(CMClockGetHostTimeClock())
        return UInt64(CMTimeConvertScale(value, timescale: 1_000_000_000, method: .default).value)
    }

    private static func makeSlate(title: String, message: String) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferCGImageCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, attributes as CFDictionary,
            &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw CameraError.allocation(status) }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw CameraError.allocation(kCVReturnAllocationFailed) }
        context.setFillColor(CGColor(gray: 0.035, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        for (text, size, y) in [
            (title, CGFloat(72), CGFloat(560)), (message, CGFloat(40), CGFloat(470)),
        ] {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    "Helvetica" as CFString, size, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    gray: 0.85, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: (1920 - width) / 2, y: y)
            CTLineDraw(line, context)
        }
        return buffer
    }
}

/// Retains one framework callback result across the explicit serial queue hop.
private final class SinkResult: @unchecked Sendable {
    let sample: CMSampleBuffer?
    let sequence: UInt64
    let hasMore: Bool
    let failed: Bool
    init(sample: CMSampleBuffer?, sequence: UInt64, hasMore: Bool, failed: Bool) {
        self.sample = sample
        self.sequence = sequence
        self.hasMore = hasMore
        self.failed = failed
    }
}

private final class CameraStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let owner: CameraDevice
    private let direction: CMIOExtensionStream.Direction
    let formats: [CMIOExtensionStreamFormat]
    private var formatSelection = FrameFormat()
    private var activeIndex: Int { formatSelection.index }
    var framesPerSecond: UInt64 { activeIndex == 0 ? 30 : 60 }
    var frameDuration: CMTime { CMTime(value: 1, timescale: Int32(framesPerSecond)) }

    init(
        owner: CameraDevice, direction: CMIOExtensionStream.Direction, name: String, id: UUID,
        description: CMFormatDescription
    ) {
        self.owner = owner
        self.direction = direction
        formats = [30, 60].map { rate in
            let duration = CMTime(value: 1, timescale: Int32(rate))
            return CMIOExtensionStreamFormat(
                formatDescription: description, maxFrameDuration: duration,
                minFrameDuration: duration, validFrameDurations: nil)
        }
        super.init()
        stream = CMIOExtensionStream(
            localizedName: name,
            streamID: id, direction: direction, clockType: .hostTime,
            source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [
            .streamActiveFormatIndex, .streamFrameDuration,
        ]
        if direction == .sink {
            properties.formUnion([
                .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
            ])
        }
        return properties
    }
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let value = CMIOExtensionStreamProperties(dictionary: [:])
        value.activeFormatIndex = activeIndex
        value.frameDuration = frameDuration
        if direction == .sink {
            value.sinkBufferQueueSize = 2
            value.sinkBuffersRequiredForStartup = 1
            value.sinkBufferUnderrunCount = owner.underruns
            value.sinkEndOfData = 0
        }
        return value
    }
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        let previous = activeIndex
        let duration = streamProperties.frameDuration
        if let duration, !duration.isNumeric || duration.epoch != 0 {
            throw CameraError.unsupportedFormat
        }
        try formatSelection.select(
            index: streamProperties.activeFormatIndex,
            durationNumerator: duration?.value, durationTimescale: duration?.timescale)
        if direction == .source, previous != activeIndex { owner.formatChanged() }
    }
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        direction == .source || owner.authorize(client)
    }
    func startStream() throws { try owner.start(direction) }
    func stopStream() throws { owner.stop(direction) }
}
