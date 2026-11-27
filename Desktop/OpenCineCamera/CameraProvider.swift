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
    /// The driver's own copy of the table, so its inputs exist before the dock next runs.
    static let slotTableURL: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("virtual-camera-slots.json")
    }()
    /// Until the dock names the inputs, one input exists so the dock has something to reach.
    static let unnamedInput = "OpenCine Camera"
    private(set) var provider: CMIOExtensionProvider!
    /// Devices by slot number. A device is added once and stays while the driver runs, so receiving
    /// apps never see an input vanish mid-session.
    private var cameras: [Int: CameraDevice] = [:]
    /// "OpenCine": the selected tab's picture. Published once, after the slots, and kept.
    private var selected: SelectedCameraDevice?
    private var table = VirtualCameraSlotTable()
    private let queue = DispatchQueue(
        label: "com.opencapture.opencine.camera.delivery", qos: .userInteractive,
        autoreleaseFrequency: .workItem)

    override init() {
        super.init()
    }

    convenience init(configured: Bool = true) throws {
        self.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: queue)
        queue.sync {
            table = (try? VirtualCameraSlotTableFile.load(from: Self.slotTableURL)) ?? table
            publishAssignedSlots()
            if cameras.isEmpty, let first = VirtualCameraSlot(number: 1) {
                publish(slot: first, name: Self.unnamedInput)
            }
            publishSelected()
        }
    }

    private func publishSelected() {
        do {
            let camera = try SelectedCameraDevice(queue: queue) { [weak self] slot in
                self?.cameras[slot.number]
            }
            try provider.addDevice(camera.device)
            selected = camera
            log.notice("Published \(SelectedVirtualCamera.displayName, privacy: .public)")
        } catch {
            log.error("Could not publish the selected input: \(error, privacy: .public)")
        }
    }

    /// A table from the dock. Refused content changes nothing, and a slot once published stays.
    private func receive(_ text: String) {
        guard let received = VirtualCameraSlotTableWire.decode(text) else { return }
        if received != table {
            table = received
            do {
                try VirtualCameraSlotTableFile.save(received, to: Self.slotTableURL)
            } catch {
                log.error("Could not keep the slot table: \(error, privacy: .public)")
            }
        }
        // The dock repeats the table, so a rename held back by an app using the input lands later.
        publishAssignedSlots()
    }

    /// Publishes each assignment. A new name replaces an input only while no receiving app is using
    /// it, and its stable ID keeps saved scenes attached. A module feeding it reconnects by itself.
    private func publishAssignedSlots() {
        for assignment in table.assignments {
            guard let slot = VirtualCameraSlot(number: assignment.slot) else { continue }
            if let existing = cameras[assignment.slot] {
                guard existing.displayName != assignment.displayName, !existing.isInUse else { continue }
                do { try provider.removeDevice(existing.device) } catch {
                    log.error("Could not rename slot \(slot.number): \(error, privacy: .public)")
                    continue
                }
                cameras[assignment.slot] = nil
            }
            publish(slot: slot, name: assignment.displayName)
        }
    }

    private func publish(slot: VirtualCameraSlot, name: String) {
        do {
            let camera = try CameraDevice(
                slot: slot, displayName: name, queue: queue,
                tableText: { [weak self] in
                    self.flatMap { try? VirtualCameraSlotTableWire.encode($0.table) } ?? ""
                },
                receiveTable: { [weak self] text in
                    // Later on the queue: this can replace the device delivering the call.
                    self?.queue.async { self?.receive(text) }
                })
            try provider.addDevice(camera.device)
            cameras[slot.number] = camera
            log.notice("Published slot \(slot.number) as \(name, privacy: .public)")
        } catch {
            log.error("Could not publish slot \(slot.number): \(error, privacy: .public)")
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

private extension CMIOExtensionProperty {
    static let slotTable = CMIOExtensionProperty(rawValue: VirtualCameraSlotTableWire.propertyName)
    static let selection = CMIOExtensionProperty(rawValue: VirtualCameraSelectionWire.propertyName)
}

private enum CameraError: Error {
    case allocation(OSStatus)
    case unsupportedFormat, producerUnavailable
}

/// What a stream asks of the device that owns it.
private protocol CameraStreamOwner: AnyObject {
    var underruns: Int { get }
    func authorize(_ client: CMIOExtensionClient) -> Bool
    func start(_ direction: CMIOExtensionStream.Direction) throws
    func stop(_ direction: CMIOExtensionStream.Direction)
    func formatChanged()
}

/// The pictures an input shows in place of a camera: not connected, and connected without picture.
private struct Slates {
    let off: CVPixelBuffer
    let waiting: CVPixelBuffer

    init(title: String) throws {
        off = try Slates.make(title: title, message: "Camera not connected")
        waiting = try Slates.make(title: title, message: "Waiting for picture")
    }

    private static func make(title: String, message: String) throws -> CVPixelBuffer {
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

/// Sends one input's pictures to its receiving apps: a frame retimed to the receiver's cadence or a
/// slate in its place, with a time discontinuity whenever what is shown changes and timestamps
/// that never go back. Serial delivery queue only.
private final class SourceFeed {
    /// The slot a picture came from (`nil` for the input's own slate), and frame or which slate.
    private struct Shown: Equatable {
        let slot: Int?
        let kind: Int
    }

    private let formatDescription: CMFormatDescription
    private var discontinuity: CMIOExtensionStream.DiscontinuityFlags = [.time]
    private var lastShown: Shown?
    private var lastOutputTime: UInt64?
    private(set) var delivered: UInt64 = 0
    private(set) var malformed: UInt64 = 0

    init(formatDescription: CMFormatDescription) {
        self.formatDescription = formatDescription
    }

    func markTimeBreak() { discontinuity.insert(.time) }
    func markDropped() { discontinuity.insert(.sampleDropped) }

    func send(
        _ output: FramePolicy<CMSampleBuffer>.Output, from slot: Int?, slates: Slates, now: UInt64,
        duration: CMTime, to stream: CMIOExtensionStream
    ) {
        let image: CVPixelBuffer
        let kind: Int
        let original: CMSampleBuffer?
        let captureHostTime: UInt64
        switch output {
        case .frame(let sample, _):
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
            image = buffer
            original = sample
            captureHostTime = UInt64(
                CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1_000_000_000)
            kind = 0
        case .slate(.feedOff):
            image = slates.off
            original = nil
            captureHostTime = now
            kind = 1
        case .slate(.noFeed):
            image = slates.waiting
            original = nil
            captureHostTime = now
            kind = 2
        }
        let shown = Shown(slot: slot, kind: kind)
        if lastShown != shown { discontinuity.insert(.time) }
        lastShown = shown
        let timestamp = lastOutputTime.map { max(now, $0 + 1) } ?? now
        lastOutputTime = timestamp
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        if let original {
            sample = try? SampleEnvelope.retime(
                original, outputTime: timing.presentationTimeStamp, duration: duration)
        } else {
            let status = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: image, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                sampleTiming: &timing, sampleBufferOut: &sample)
            guard status == noErr else {
                malformed &+= 1
                return
            }
        }
        guard let sample else {
            malformed &+= 1
            return
        }
        signposter.emitEvent("Camera delivery")
        stream.send(sample, discontinuity: discontinuity, hostTimeInNanoseconds: captureHostTime)
        discontinuity = []
        delivered &+= 1
    }
}

/// "OpenCine": one source with no sink. It shows the slot the dock says is selected, read from that
/// slot's frame policy on this queue, so a tab switch lands on the next frame on the same device.
private final class SelectedCameraDevice: NSObject, CMIOExtensionDeviceSource, CameraStreamOwner,
    @unchecked Sendable
{
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStream!
    private let queue: DispatchQueue
    private let router = SelectedInputRouter<CMSampleBuffer>()
    private let feed: SourceFeed
    private let slates: Slates
    private let camera: (VirtualCameraSlot) -> CameraDevice?
    private var sourceStarts = 0
    private var timer: DispatchSourceTimer?
    private var cadence = FrameCadence(framesPerSecond: 30)
    private var lastDiagnostics: UInt64 = 0
    let underruns = 0

    init(queue: DispatchQueue, camera: @escaping (VirtualCameraSlot) -> CameraDevice?) throws {
        self.queue = queue
        self.camera = camera
        let formatDescription = try CMFormatDescription(
            videoCodecType: CMFormatDescription.MediaSubType(rawValue: kCVPixelFormatType_32BGRA),
            width: 1920, height: 1080)
        feed = SourceFeed(formatDescription: formatDescription)
        slates = try Slates(title: SelectedVirtualCamera.displayName)
        super.init()
        device = CMIOExtensionDevice(
            localizedName: SelectedVirtualCamera.displayName,
            deviceID: SelectedVirtualCamera.deviceUUID,
            legacyDeviceID: SelectedVirtualCamera.legacyDeviceID, source: self)
        source = CameraStream(
            owner: self, direction: .source, name: SelectedVirtualCamera.displayName,
            id: SelectedVirtualCamera.sourceStreamUUID, description: formatDescription)
        try device.addStream(source.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, .selection]
    }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let value = CMIOExtensionDeviceProperties(dictionary: [:])
        value.transportType = 0x7669_7274
        value.model = SelectedVirtualCamera.displayName
        value.setPropertyState(
            CMIOExtensionPropertyState(
                value: VirtualCameraSelectionWire.encode(router.selection) as NSString),
            forProperty: .selection)
        return value
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        guard let text = deviceProperties.propertiesDictionary[.selection]?.value as? String,
            let selection = VirtualCameraSelectionWire.decode(text)
        else { return }
        if router.select(selection) {
            log.notice("OpenCine follows slot \(selection.slot?.number ?? 0)")
        }
    }

    func authorize(_ client: CMIOExtensionClient) -> Bool { false }

    func start(_ direction: CMIOExtensionStream.Direction) throws {
        guard direction == .source else { throw CameraError.producerUnavailable }
        sourceStarts += 1
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
        guard direction == .source else { return }
        sourceStarts = max(0, sourceStarts - 1)
        guard sourceStarts == 0 else { return }
        timer?.cancel()
        timer = nil
    }

    func formatChanged() {
        cadence.reset(framesPerSecond: source.framesPerSecond)
        feed.markTimeBreak()
    }

    private func tick() {
        let now = CameraDevice.hostNow()
        let previousSkipped = cadence.skipped
        if sourceStarts > 0, cadence.isDue(now: now) {
            if cadence.skipped > previousSkipped { feed.markDropped() }
            let picture = router.output(now: now) { [camera] in camera($0)?.policy }
            let shownSlates = picture.slot.flatMap { camera($0)?.slates } ?? slates
            feed.send(
                picture.output, from: picture.slot?.number, slates: shownSlates, now: now,
                duration: source.frameDuration, to: source.stream)
        }
        if now > lastDiagnostics + 10_000_000_000 {
            lastDiagnostics = now
            log.info(
                "selected=\(self.router.selection.slot?.number ?? 0) delivery=\(self.feed.delivered) malformed=\(self.feed.malformed) skipped=\(self.cadence.skipped)"
            )
        }
    }
}

/// A stable device with one public source and one authenticated producer sink.
private final class CameraDevice: NSObject, CMIOExtensionDeviceSource, CameraStreamOwner,
    @unchecked Sendable
{
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStream!
    private var sink: CameraStream!
    private let queue: DispatchQueue
    /// Also read by "OpenCine" while this slot is selected.
    let policy = FramePolicy<CMSampleBuffer>()
    let slates: Slates
    private let feed: SourceFeed
    private var producer: CMIOExtensionClient?
    private var producerEpoch: UInt64 = 0
    private var sourceStarts = 0
    private var sinkStarted = false
    private var consumeOutstanding = false
    private var timer: DispatchSourceTimer?
    private var cadence = FrameCadence(framesPerSecond: 30)
    private(set) var underruns = 0
    private var malformed: UInt64 = 0
    private var lastDiagnostics: UInt64 = 0

    private let slot: VirtualCameraSlot
    let displayName: String
    private let tableText: () -> String
    private let receiveTable: (String) -> Void
    var isInUse: Bool { sourceStarts > 0 }

    init(
        slot: VirtualCameraSlot, displayName: String, queue: DispatchQueue,
        tableText: @escaping () -> String, receiveTable: @escaping (String) -> Void
    ) throws {
        self.slot = slot
        self.displayName = displayName
        self.queue = queue
        self.tableText = tableText
        self.receiveTable = receiveTable
        let formatDescription = try CMFormatDescription(
            videoCodecType: CMFormatDescription.MediaSubType(rawValue: kCVPixelFormatType_32BGRA),
            width: 1920, height: 1080)
        feed = SourceFeed(formatDescription: formatDescription)
        slates = try Slates(title: displayName)
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

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, .slotTable]
    }
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let value = CMIOExtensionDeviceProperties(dictionary: [:])
        value.transportType = 0x7669_7274
        value.model = displayName
        value.setPropertyState(
            CMIOExtensionPropertyState(value: tableText() as NSString), forProperty: .slotTable)
        return value
    }
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        if let text = deviceProperties.propertiesDictionary[.slotTable]?.value as? String {
            receiveTable(text)
        }
    }

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
        feed.markTimeBreak()
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
        feed.markTimeBreak()
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
            if cadence.skipped > previousSkipped { feed.markDropped() }
            feed.send(
                policy.output(now: now), from: slot.number, slates: slates, now: now,
                duration: source.frameDuration, to: source.stream)
        }
        if now > lastDiagnostics + 10_000_000_000 {
            lastDiagnostics = now
            log.info(
                "delivery=\(self.feed.delivered) replaced=\(self.policy.replaced) repeats=\(self.policy.repeats) rejected=\(self.policy.rejected) malformed=\(self.malformed + self.feed.malformed) skipped=\(self.cadence.skipped) underruns=\(self.underruns)"
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

    func formatChanged() {
        cadence.reset(framesPerSecond: source.framesPerSecond)
        feed.markTimeBreak()
    }

    static func hostNow() -> UInt64 {
        let value = CMClockGetTime(CMClockGetHostTimeClock())
        return UInt64(CMTimeConvertScale(value, timescale: 1_000_000_000, method: .default).value)
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
    private unowned let owner: any CameraStreamOwner
    private let direction: CMIOExtensionStream.Direction
    let formats: [CMIOExtensionStreamFormat]
    private var formatSelection = FrameFormat()
    private var activeIndex: Int { formatSelection.index }
    var framesPerSecond: UInt64 { activeIndex == 0 ? 30 : 60 }
    var frameDuration: CMTime { CMTime(value: 1, timescale: Int32(framesPerSecond)) }

    init(
        owner: any CameraStreamOwner, direction: CMIOExtensionStream.Direction, name: String, id: UUID,
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
