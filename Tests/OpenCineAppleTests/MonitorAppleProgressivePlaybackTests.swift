#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import CoreVideo
    import Foundation
    import OpenCineApple
    import OpenCineMedia
    import Testing
    import os

    /// Real native decode coverage. Polls wait for AVFoundation, not a portable policy clock.
    @MainActor @Suite(.serialized) struct MonitorAppleProgressivePlaybackTests {
        #if canImport(UIKit)
            @Test func actualPreparedOwnerPublishesNativeTimeRangeAndRejectsRetirementReentry()
                async throws
            {
                let directory = try fixtureDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("buffer-observation.mov")
                try await writeMovie(at: url)
                let native = MonitorApplePlaybackOwner(
                    feed: MonitorPlaybackFeedSession(
                        configuration: .init(), hdrDisplay: { false }))
                let token = MonitorPlaybackItemToken(owner: UUID(), revision: 0)
                native.retireItem(for: token)
                defer { native.close(token: token) }
                _ = try await native.prepare(
                    .init(url: url, mimeType: "video/quicktime", sourceKey: "SIMULATED-buffer"),
                    token: token, readyTimeout: .seconds(8))
                let end = ContinuousClock.now.advanced(by: .seconds(8))
                while native.bufferedThroughSeconds(token: token) == nil, ContinuousClock.now < end
                {
                    try await Task.sleep(for: .milliseconds(10))
                }
                let item = try #require(native.player.currentItem)
                let observed = try #require(native.bufferedThroughSeconds(token: token))
                let expected = try #require(
                    item.loadedTimeRanges.map {
                        CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue))
                    }.filter { $0.isFinite && $0 >= 0 }.max())
                #expect(abs(observed - expected) < 0.001)
                native.sourceAdmission = { false }
                #expect(native.bufferedThroughSeconds(token: token) == nil)
                native.sourceAdmission = { true }
                let successor = MonitorPlaybackItemToken(owner: token.owner, revision: 1)
                native.sourceAdmission = {
                    native.sourceAdmission = nil
                    native.retireItem(for: successor)
                    return true
                }
                #expect(native.bufferedThroughSeconds(token: token) == nil)
                #expect(native.player.currentItem == nil)
                native.close(token: successor)
                #expect(native.bufferedThroughSeconds(token: successor) == nil)
            }
        #endif

        @Test func growingPrefixStopsClockAndRecoversChangedPixelsAfterCompletionRename()
            async throws
        {
            try await exerciseGrowingFile(pauseDuringWait: false, replacePath: true)
        }

        @Test func pauseDuringBufferWaitCannotResumeWhenBytesArrive() async throws {
            try await exerciseGrowingFile(pauseDuringWait: true, replacePath: false)
        }

        @Test func failedTransferAtTemporaryEOFReportsCapturedFailureWithoutDeletingItsPrefix()
            async throws
        {
            try await exerciseGrowingFile(
                pauseDuringWait: false, replacePath: false, failDuringWait: true)
        }

        @Test func explicitCloseSuppressesQueuedFailureAndLateUpdates() async throws {
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("retired.mov")
            let prefix = Data(repeating: 0xAB, count: 8)
            try prefix.write(to: url)
            let progressive = try await MonitorAppleProgressiveAsset(
                file: url, contentLength: 16, contentType: .mov, readableBytes: 8)
            var failures: [MonitorAppleProgressiveAssetError] = []
            progressive.onFailure = { failures.append($0) }
            // Close on Main before the delegate's terminal failure can publish on Main.
            progressive.fail()
            progressive.close()
            progressive.fail()
            progressive.update(readableBytes: 16)
            progressive.finish()
            let deliveredEnd = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deliveredEnd { await Task.yield() }
            #expect(failures.isEmpty)
            #expect(try Data(contentsOf: url) == prefix)
        }

        @Test func openingRejectsInventedLengthAndBytesBeyondTheActualFile() async throws {
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("source.mov")
            try Data(repeating: 0, count: 8).write(to: url)
            do {
                _ = try await MonitorAppleProgressiveAsset(
                    file: url, contentLength: 0, contentType: .mov, readableBytes: 0)
                Issue.record("An unknown length cannot become a native content-length fact")
            } catch {
                #expect(error as? MonitorAppleProgressiveAssetError == .invalidLength)
            }
            do {
                _ = try await MonitorAppleProgressiveAsset(
                    file: url, contentLength: 16, contentType: .mov, readableBytes: 9)
                Issue.record("Advertised bytes must already exist on the opened descriptor")
            } catch {
                #expect(error as? MonitorAppleProgressiveAssetError == .invalidReadableBytes)
            }
        }

        @Test func retirementDuringAdmissionCannotPlayTheReplacedNativeItem() throws {
            let player = AVPlayer()
            let outgoing = AVPlayerItem(url: URL(fileURLWithPath: "/SIMULATED/outgoing.mov"))
            let successor = AVPlayerItem(url: URL(fileURLWithPath: "/SIMULATED/successor.mov"))
            player.replaceCurrentItem(with: outgoing)
            var publications = 0
            let recovery = MonitorApplePlaybackBufferRecovery(
                player: player, item: outgoing,
                isCurrent: {
                    player.replaceCurrentItem(with: successor)
                    return true
                }, onTransport: { _ in publications += 1 })
            recovery.play(rate: 1)
            #expect(player.currentItem === successor)
            #expect(player.rate == 0)
            #expect(publications == 0)
            recovery.close()
            player.replaceCurrentItem(with: nil)
        }

        @Test func starvationAndRefillBeforeMainDeliveryStillResumeTheAdmittedRate() async throws {
            try await exerciseQueuedBufferEdges(pauseBeforeDelivery: false)
        }

        @Test func pauseBeforeQueuedStarvationDeliveryCannotResurrectPlayback() async throws {
            try await exerciseQueuedBufferEdges(pauseBeforeDelivery: true)
        }

        private func exerciseQueuedBufferEdges(pauseBeforeDelivery: Bool) async throws {
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("burst.mov")
            try await writeMovie(at: url)
            let item = ControlledBufferItem(url: url)
            let player = ControlledRatePlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            defer {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            let readyEnd = ContinuousClock.now.advanced(by: .seconds(8))
            while item.status == .unknown, ContinuousClock.now < readyEnd {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(item.status == .readyToPlay)
            let recovery = MonitorApplePlaybackBufferRecovery(
                player: player, item: item,
                isCurrent: { player.currentItem === item }, onTransport: { _ in })
            defer { recovery.close() }
            recovery.play(rate: 1)
            // Native starvation resets rate to zero while the admitted operator intent remains.
            player.pause()
            #expect(player.rate == 0)
            item.publishBufferEmpty(true)
            item.publishBufferEmpty(false)
            // Both actual KVO observations are queued before MainActor is allowed to deliver them.
            if pauseBeforeDelivery { recovery.pause() }
            let deliveredEnd = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deliveredEnd,
                pauseBeforeDelivery || player.rate == 0
            {
                await Task.yield()
            }
            #expect(player.rate == (pauseBeforeDelivery ? 0 : 1))
        }

        private func exerciseGrowingFile(
            pauseDuringWait: Bool, replacePath: Bool, failDuringWait: Bool = false
        ) async throws {
            let directory = try fixtureDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let complete = directory.appendingPathComponent("complete.mov")
            try await writeMovie(at: complete)
            let bytes = try Data(contentsOf: complete)
            let prefix = try prefixEnd(bytes)
            let growing = directory.appendingPathComponent("growing.mov")
            try bytes.prefix(prefix).write(to: growing)
            let writer = try FileHandle(forWritingTo: growing)
            defer { try? writer.close() }
            let progressive = try await MonitorAppleProgressiveAsset(
                file: growing, contentLength: Int64(bytes.count), contentType: .mov,
                readableBytes: Int64(prefix))
            defer { progressive.close() }
            let item = AVPlayerItem(asset: progressive.asset)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            defer {
                player.pause()
                player.replaceCurrentItem(with: nil)
                item.remove(output)
            }
            let readyEnd = ContinuousClock.now.advanced(by: .seconds(8))
            while item.status == .unknown, ContinuousClock.now < readyEnd {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(item.status == .readyToPlay, "\(String(describing: item.error))")
            var transport: MonitorPlaybackTransportState?
            let recovery = MonitorApplePlaybackBufferRecovery(
                player: player, item: item,
                isCurrent: { player.currentItem === item }, onTransport: { transport = $0 })
            defer { recovery.close() }
            recovery.play(rate: 1)
            var sample = PixelSample()
            var largestClockLead = 0.0
            let heldEnd = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < heldEnd {
                sample.read(player, output)
                if sample.changedTime >= 0 {
                    largestClockLead = max(
                        largestClockLead, player.currentTime().seconds - sample.changedTime)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let heldChanged = sample.changedTime
            #expect(sample.changedFrames > 0)
            #expect(heldChanged > 0.5, "The prefix must play before transfer completion")
            #expect(player.currentTime().seconds <= heldChanged + 0.5)
            #expect(largestClockLead <= 0.5)
            #expect(transport == .waiting)
            if failDuringWait {
                var failures: [MonitorAppleProgressiveAssetError] = []
                progressive.onFailure = { failures.append($0) }
                progressive.fail()
                progressive.fail()
                let failureEnd = ContinuousClock.now.advanced(by: .seconds(4))
                while failures.isEmpty, ContinuousClock.now < failureEnd {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(failures == [.incompleteTransfer])
                progressive.fail()
                progressive.finish()
                progressive.update(readableBytes: Int64(bytes.count))
                #expect(failures == [.incompleteTransfer])
                #expect(try Data(contentsOf: growing) == bytes.prefix(prefix))
                return
            }
            if pauseDuringWait { recovery.pause() }
            if replacePath {
                try FileManager.default.moveItem(
                    at: growing, to: directory.appendingPathComponent("renamed.mov"))
                // The loader must not follow an unrelated successor at the old cache path.
                try Data(repeating: 0xEE, count: bytes.count).write(to: growing)
            }
            try writer.seekToEnd()
            try writer.write(contentsOf: bytes.suffix(from: prefix))
            progressive.update(readableBytes: Int64(bytes.count))
            progressive.finish()
            let resumedEnd = ContinuousClock.now.advanced(by: .seconds(4))
            while ContinuousClock.now < resumedEnd,
                pauseDuringWait || sample.changedTime <= heldChanged + 0.5
            {
                sample.read(player, output)
                try await Task.sleep(for: .milliseconds(10))
            }
            if pauseDuringWait {
                #expect(sample.changedTime <= heldChanged + 0.5)
                #expect(player.rate == 0)
                #expect(transport == .paused)
            } else {
                #expect(sample.changedTime > heldChanged + 0.5)
                #expect(player.rate > 0)
                #expect(transport == .playing)
            }
        }

        private struct PixelSample {
            var changedTime = -1.0
            var changedFrames = 0
            private var fingerprint: UInt64?

            mutating func read(_ player: AVPlayer, _ output: AVPlayerItemVideoOutput) {
                let time = player.currentTime()
                var decoded = CMTime.invalid
                guard output.hasNewPixelBuffer(forItemTime: time),
                    let buffer = output.copyPixelBuffer(
                        forItemTime: time, itemTimeForDisplay: &decoded),
                    decoded.isValid, decoded.seconds.isFinite
                else { return }
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard
                    let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(
                        to: UInt8.self)
                else { return }
                let width = CVPixelBufferGetWidth(buffer)
                let height = CVPixelBufferGetHeight(buffer)
                guard width > 0, height > 0 else { return }
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                var hash: UInt64 = 14_695_981_039_346_656_037
                for y in [0, height / 3, height / 2, height - 1] {
                    for x in [0, width / 3, width / 2, width - 1] {
                        for channel in 0..<3 {
                            hash =
                                (hash ^ UInt64(base[y * stride + x * 4 + channel]))
                                &* 1_099_511_628_211
                        }
                    }
                }
                if fingerprint != hash {
                    fingerprint = hash
                    changedTime = decoded.seconds
                    changedFrames += 1
                }
            }
        }

        private func fixtureDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            return directory
        }

        private func writeMovie(at url: URL) async throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer.shouldOptimizeForNetworkUse = true
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128,
                    AVVideoHeightKey: 96,
                    AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 1],
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 96,
                ])
            writer.add(input)
            try #require(writer.startWriting())
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<60 {
                let until = ContinuousClock.now.advanced(by: .seconds(5))
                while !input.isReadyForMoreMediaData, writer.status == .writing,
                    ContinuousClock.now < until
                {
                    try await Task.sleep(for: .milliseconds(1))
                }
                try #require(input.isReadyForMoreMediaData)
                let pool = try #require(adaptor.pixelBufferPool)
                var optional: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(
                    kCFAllocatorDefault, pool, &optional)
                try #require(status == kCVReturnSuccess)
                let buffer = try #require(optional)
                CVPixelBufferLockBaseAddress(buffer, [])
                guard
                    let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(
                        to: UInt8.self)
                else { throw CocoaError(.coderInvalidValue) }
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<96 {
                    for x in 0..<128 {
                        let pixel = base + y * stride + x * 4
                        pixel[0] = UInt8((x + frame * 3) % 255)
                        pixel[1] = UInt8((y + frame * 5) % 255)
                        pixel[2] = UInt8((frame * 7) % 255)
                        pixel[3] = 255
                    }
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                try #require(
                    adaptor.append(
                        buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
            }
            input.markAsFinished()
            await withCheckedContinuation { continuation in
                writer.finishWriting { continuation.resume() }
            }
            try #require(writer.status == .completed)
        }

        private func prefixEnd(_ data: Data) throws -> Int {
            var cursor = 0
            while cursor + 8 <= data.count {
                var size = data[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
                let type = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
                var header = 8
                if size == 1, cursor + 16 <= data.count {
                    size = data[(cursor + 8)..<(cursor + 16)].reduce(0) { ($0 << 8) | Int($1) }
                    header = 16
                }
                guard size >= header, cursor + size <= data.count else { break }
                if type == "mdat" {
                    return cursor + header + max(1, (size - header) * 35 / 100)
                }
                cursor += size
            }
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// Emits the native KVO key synchronously while its observed value remains thread-safe.
    /// The real AVPlayer item, actor delivery and recovery code remain under test.
    private final class ControlledBufferItem: AVPlayerItem, @unchecked Sendable {
        private let empty = OSAllocatedUnfairLock(initialState: false)

        override var isPlaybackBufferEmpty: Bool { empty.withLock { $0 } }

        func publishBufferEmpty(_ value: Bool) {
            willChangeValue(forKey: "playbackBufferEmpty")
            empty.withLock { $0 = value }
            didChangeValue(forKey: "playbackBufferEmpty")
        }
    }

    /// Isolates requested native rate writes from AVPlayer's independent decode scheduling.
    /// The real item/KVO path is unchanged; the pixel cases exercise actual native playback.
    private final class ControlledRatePlayer: AVPlayer, @unchecked Sendable {
        private let admittedRate = OSAllocatedUnfairLock(initialState: Float.zero)

        override var rate: Float {
            get { admittedRate.withLock { $0 } }
            set { admittedRate.withLock { $0 = newValue } }
        }

        override func pause() { rate = 0 }
    }
#endif
