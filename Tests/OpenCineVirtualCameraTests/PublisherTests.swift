#if canImport(CoreMediaIO)
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import OpenCineVirtualCamera

@Suite("Mac virtual camera bounded publisher")
struct PublisherTests {
    final class Frame {
        let number: Int
        init(_ number: Int) { self.number = number }
    }

    @Test func slowConsumerKeepsOnlyNewestPendingFrame() {
        let mailbox = VirtualCameraMailbox<Frame>()
        let generation = mailbox.setEnabled(true)
        weak var retired: Frame?
        do {
            let frame = Frame(1)
            retired = frame
            mailbox.offer(frame, generation: generation)
        }
        for number in 2...1_000 { mailbox.offer(Frame(number), generation: generation) }
        #expect(retired == nil)
        #expect(mailbox.take(canConsume: false) == nil)
        #expect(mailbox.take(canConsume: true)?.frame.number == 1_000)
        #expect(mailbox.take(canConsume: true) == nil)
        #expect(mailbox.snapshot.replaced == 999)
    }

    @Test func disableReleasesPendingAndRejectsInflightWork() {
        let mailbox = VirtualCameraMailbox<Frame>()
        let generation = mailbox.setEnabled(true)
        mailbox.offer(Frame(1), generation: generation)
        let inFlight = mailbox.take(canConsume: true)
        #expect(inFlight?.frame.number == 1)
        weak var pending: Frame?
        do {
            let frame = Frame(2)
            pending = frame
            mailbox.offer(frame, generation: generation)
        }
        #expect(pending != nil)
        mailbox.setEnabled(false)
        #expect(pending == nil)
        var published = false
        _ = mailbox.withAdmission(generation: inFlight?.generation ?? 0) { published = true }
        #expect(!published)
        #expect(mailbox.take(canConsume: true) == nil)
        mailbox.offer(Frame(3), generation: generation)
        #expect(mailbox.take(canConsume: true) == nil)
    }

    @Test func enableTogglePreservesSourceTokenButRetiresInflightPublication() {
        let mailbox = VirtualCameraMailbox<Frame>()
        let source = mailbox.resetSource()
        mailbox.setEnabled(true)
        mailbox.offer(Frame(1), generation: source)
        let inFlight = mailbox.take(canConsume: true)
        #expect(inFlight?.frame.number == 1)
        mailbox.setEnabled(false)
        mailbox.setEnabled(true)
        var published = false
        _ = mailbox.withAdmission(generation: inFlight?.generation ?? 0) { published = true }
        #expect(!published)
        mailbox.offer(Frame(2), generation: source)
        #expect(mailbox.take(canConsume: true)?.frame.number == 2)
    }

    @Test func sourceResetRejectsRetiredCallbacksAcrossEnableCycles() {
        let mailbox = VirtualCameraMailbox<Frame>()
        let first = mailbox.setEnabled(true)
        mailbox.offer(Frame(1), generation: first)
        let second = mailbox.resetSource()
        mailbox.offer(Frame(2), generation: first)
        #expect(mailbox.take(canConsume: true) == nil)
        mailbox.offer(Frame(3), generation: second)
        #expect(mailbox.take(canConsume: true)?.frame.number == 3)
        mailbox.setEnabled(false)
        mailbox.setEnabled(true)
        mailbox.offer(Frame(4), generation: first)
        mailbox.offer(Frame(5), generation: second)
        #expect(mailbox.take(canConsume: true)?.frame.number == 5)
    }
}

@Suite("Mac virtual camera host timing")
struct PublisherTimelineTests {
    @Test func sourceCadenceMapsToHostMonotonicEpoch() {
        var timeline = VirtualCameraTimeline()
        #expect(
            timeline.map(
                CMTime(value: 0, timescale: 30),
                hostNow: CMTime(seconds: 100, preferredTimescale: 600))
                == CMTime(seconds: 100, preferredTimescale: 600))
        #expect(
            timeline.map(
                CMTime(value: 1, timescale: 30),
                hostNow: CMTime(seconds: 101, preferredTimescale: 600))
                == CMTime(value: 3_001, timescale: 30))
    }

    @Test func sourceRegressionAndMalformedTimestampAreRejected() {
        var timeline = VirtualCameraTimeline()
        _ = timeline.map(
            CMTime(value: 50, timescale: 30), hostNow: CMTime(seconds: 100, preferredTimescale: 600)
        )
        #expect(
            timeline.map(
                CMTime(value: 49, timescale: 30),
                hostNow: CMTime(seconds: 100, preferredTimescale: 600)) == nil)
        #expect(
            timeline.map(.invalid, hostNow: CMTime(seconds: 100, preferredTimescale: 600)) == nil)
        #expect(
            timeline.map(.indefinite, hostNow: CMTime(seconds: 100, preferredTimescale: 600)) == nil
        )
    }

    @Test func sourceResetStartsFreshHostEpoch() {
        var timeline = VirtualCameraTimeline()
        _ = timeline.map(
            CMTime(seconds: 50, preferredTimescale: 600),
            hostNow: CMTime(seconds: 100, preferredTimescale: 600))
        timeline.reset()
        #expect(
            timeline.map(.zero, hostNow: CMTime(seconds: 200, preferredTimescale: 600))
                == CMTime(seconds: 200, preferredTimescale: 600))
    }
}

@Suite("Mac virtual camera native output")
struct PublisherOutputTests {
    @Test func frameworkQueueNeverBuildsBacklogEvenWhenCapacityIsLarger() throws {
        var rawQueue: CMSimpleQueue?
        #expect(
            CMSimpleQueueCreate(allocator: kCFAllocatorDefault, capacity: 8, queueOut: &rawQueue)
                == noErr)
        let queue = try #require(rawQueue)
        let output = VirtualCameraSampleQueue(queue)
        let converter = VirtualCameraConverter()
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
            to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let buffer = try #require(converter.convert(image))
        var format: CMVideoFormatDescription?
        #expect(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
                == noErr)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: buffer,
                formatDescription: try #require(format), sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr)
        let sampleBuffer = try #require(sample)
        let firstAccepted = output.enqueue(sampleBuffer)
        let secondAccepted = output.enqueue(sampleBuffer)
        #expect(firstAccepted)
        #expect(!secondAccepted)
        #expect(CMSimpleQueueGetCount(queue) == 1)
        let token = try #require(CMSimpleQueueDequeue(queue))
        let consumed = Unmanaged<CMSampleBuffer>.fromOpaque(token).takeRetainedValue()
        #expect(consumed === sampleBuffer)
        #expect(output.hasSpace)
    }

    @Test func unmanagedSourceCodesMatchEncodedSRGBMonitorWorkingSpace() throws {
        let converter = VirtualCameraConverter()
        let image = CIImage(
            bitmapData: Data([128, 128, 128, 255]), bytesPerRow: 4,
            size: CGSize(width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let output = try #require(converter.convert(image))
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let base = try #require(
            CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self))
        let center = 540 * CVPixelBufferGetBytesPerRow(output) + 960 * 4
        #expect((127...129).contains(Int(base[center])))
        #expect((127...129).contains(Int(base[center + 1])))
        #expect((127...129).contains(Int(base[center + 2])))
    }

    @Test func conversionPoolBoundsRetainedOutputAndRecoversAfterRelease() throws {
        let converter = VirtualCameraConverter()
        let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(
            to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var held: [CVPixelBuffer] = []
        for _ in 0..<4 { held.append(try #require(converter.convert(source))) }
        #expect(converter.convert(source) == nil)
        held.removeLast()
        #expect(converter.convert(source) != nil)
        let buffer = try #require(held.first)
        #expect(CVPixelBufferGetWidth(buffer) == 1_920)
        #expect(CVPixelBufferGetHeight(buffer) == 1_080)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(
            CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self))
        let center = 540 * CVPixelBufferGetBytesPerRow(buffer) + 960 * 4
        #expect(base[center + 2] > 250)
        #expect(base[center + 1] < 5)
        #expect(base[center] < 5)
        let edge = 540 * CVPixelBufferGetBytesPerRow(buffer)
        #expect(base[edge] == 0)
        #expect(base[edge + 1] == 0)
        #expect(base[edge + 2] == 0)
    }
}

#endif
