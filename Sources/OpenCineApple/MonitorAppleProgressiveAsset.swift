#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Darwin
    import Foundation

    public enum MonitorAppleProgressiveAssetError: Error, LocalizedError, Equatable, Sendable {
        case invalidLength, invalidReadableBytes, invalidContentType
        case sourceUnavailable, invalidRange, incompleteTransfer, retired

        public var errorDescription: String? {
            switch self {
            case .invalidLength: "The clip's full length is unavailable."
            case .invalidReadableBytes: "The clip's cached bytes are unavailable."
            case .invalidContentType: "The clip's format is unavailable."
            case .sourceUnavailable: "The clip's cached file could not be read."
            case .invalidRange: "The player requested an invalid byte range."
            case .incompleteTransfer: "The clip transfer did not complete."
            case .retired: "This playback source has retired."
            }
        }
    }

    /// AVFoundation byte-range access to an explicitly growing, already-owned cache file.
    /// The host owns writes, transfer completion and deletion. This owner never follows a
    /// replacement path: the opened descriptor survives a completion rename of the same inode.
    @MainActor public final class MonitorAppleProgressiveAsset {
        public let asset: AVURLAsset
        /// A terminal cache/read failure, delivered once on Main. Explicit close is silent.
        /// Capture the exact item/source in this callback; AVPlayerItem may remain ready at EOF.
        public var onFailure: (@MainActor @Sendable (MonitorAppleProgressiveAssetError) -> Void)?
        private let loader: Loader
        private var closed = false

        /// `contentLength` and `contentType` are real host facts, not the partial file's length.
        /// Opening and reading the cache occur on this source's private serial delegate queue.
        public init(
            file: URL, contentLength: Int64, contentType: AVFileType, readableBytes: Int64
        ) async throws {
            guard file.isFileURL, contentLength > 0 else {
                throw MonitorAppleProgressiveAssetError.invalidLength
            }
            guard readableBytes >= 0, readableBytes <= contentLength else {
                throw MonitorAppleProgressiveAssetError.invalidReadableBytes
            }
            guard !contentType.rawValue.isEmpty else {
                throw MonitorAppleProgressiveAssetError.invalidContentType
            }
            let queue = DispatchQueue(label: "opencine.playback.progressive")
            let opened = try await Loader.open(
                file: file, length: contentLength, contentType: contentType.rawValue,
                available: readableBytes, queue: queue)
            guard !Task.isCancelled else {
                opened.close(error: .retired)
                throw MonitorAppleProgressiveAssetError.retired
            }
            loader = opened
            var resource = URLComponents()
            resource.scheme = "opencine-progressive"
            resource.host = UUID().uuidString
            resource.path = "/" + file.lastPathComponent
            guard let url = resource.url else {
                opened.close(error: .sourceUnavailable)
                throw MonitorAppleProgressiveAssetError.sourceUnavailable
            }
            asset = AVURLAsset(
                url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            opened.observeFailures { [weak self] error in
                guard let self, !self.closed else { return }
                self.closed = true
                self.onFailure?(error)
            }
            asset.resourceLoader.setDelegate(opened, queue: queue)
        }

        /// Call after the existing writer publishes bytes. Counts must increase monotonically,
        /// fit the declared length and already exist on this FD; invalid counts fail its requests.
        public func update(readableBytes: Int64) {
            guard !closed else { return }
            loader.update(readableBytes: readableBytes)
        }

        /// Terminates outstanding reads at the declared real EOF, only after it exists on disk.
        public func finish() {
            guard !closed else { return }
            loader.finish()
        }

        /// Fails outstanding reads without canceling or deleting the host's resumable transfer.
        public func fail() {
            guard !closed else { return }
            loader.close(error: .incompleteTransfer)
        }

        /// Retires this source once. Late updates cannot reopen requests or borrow another file.
        public func close() {
            closed = true
            asset.cancelLoading()
            loader.close(error: .retired)
        }

        deinit { loader.close(error: .retired) }

        // All mutable state, request callbacks and descriptor IO are confined to `queue`.
        private final class Loader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
            let queue: DispatchQueue
            private let handle: FileHandle
            private let length: Int64
            private let contentType: String
            private var available: Int64
            private var pending: [AVAssetResourceLoadingRequest] = []
            private var closed = false
            private var drainScheduled = false
            private var onFailure:
                (@MainActor @Sendable (MonitorAppleProgressiveAssetError) -> Void)?

            private init(
                handle: FileHandle, length: Int64, contentType: String, available: Int64,
                queue: DispatchQueue
            ) {
                self.handle = handle
                self.length = length
                self.contentType = contentType
                self.available = available
                self.queue = queue
            }

            static func open(
                file: URL, length: Int64, contentType: String, available: Int64,
                queue: DispatchQueue
            ) async throws -> Loader {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        let descriptor = file.withUnsafeFileSystemRepresentation {
                            guard let path = $0 else { return Int32(-1) }
                            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                        }
                        guard descriptor >= 0 else {
                            continuation.resume(
                                throwing: MonitorAppleProgressiveAssetError.sourceUnavailable)
                            return
                        }
                        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                        do {
                            var status = stat()
                            guard fstat(descriptor, &status) == 0,
                                status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                            else { throw MonitorAppleProgressiveAssetError.sourceUnavailable }
                            guard try handle.seekToEnd() >= UInt64(available) else {
                                throw MonitorAppleProgressiveAssetError.invalidReadableBytes
                            }
                            continuation.resume(
                                returning: Loader(
                                    handle: handle, length: length, contentType: contentType,
                                    available: available, queue: queue))
                        } catch {
                            try? handle.close()
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }

            func update(readableBytes: Int64) {
                queue.async { [self] in
                    guard !closed else { return }
                    do {
                        let extent = try handle.seekToEnd()
                        guard readableBytes >= available, readableBytes <= length,
                            readableBytes >= 0, UInt64(readableBytes) <= extent
                        else { throw MonitorAppleProgressiveAssetError.invalidReadableBytes }
                        available = readableBytes
                        scheduleDrain()
                    } catch { retire(error: error) }
                }
            }

            func finish() {
                queue.async { [self] in
                    guard !closed else { return }
                    do {
                        guard try handle.seekToEnd() >= UInt64(length) else {
                            throw MonitorAppleProgressiveAssetError.incompleteTransfer
                        }
                        available = length
                        scheduleDrain()
                    } catch { retire(error: error) }
                }
            }

            func close(error: MonitorAppleProgressiveAssetError) {
                queue.async { [self] in retire(error: error) }
            }

            func observeFailures(
                _ callback:
                    @escaping @MainActor @Sendable (MonitorAppleProgressiveAssetError) -> Void
            ) {
                queue.async { [self] in onFailure = callback }
            }

            func resourceLoader(
                _ resourceLoader: AVAssetResourceLoader,
                shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
            ) -> Bool {
                dispatchPrecondition(condition: .onQueue(queue))
                guard !closed else {
                    request.finishLoading(with: MonitorAppleProgressiveAssetError.retired)
                    return true
                }
                if let content = request.contentInformationRequest {
                    if let allowed = content.allowedContentTypes, !allowed.isEmpty,
                        !allowed.contains(contentType)
                    {
                        request.finishLoading(
                            with: MonitorAppleProgressiveAssetError.invalidContentType)
                        return true
                    }
                    content.contentType = contentType
                    content.contentLength = length
                    content.isByteRangeAccessSupported = true
                    content.isEntireLengthAvailableOnDemand = available == length
                }
                pending.append(request)
                scheduleDrain()
                return true
            }

            func resourceLoader(
                _ resourceLoader: AVAssetResourceLoader,
                didCancel request: AVAssetResourceLoadingRequest
            ) {
                dispatchPrecondition(condition: .onQueue(queue))
                remove(request)
            }

            private func scheduleDrain() {
                guard !closed, !drainScheduled else { return }
                drainScheduled = true
                queue.async { [self] in
                    drainScheduled = false
                    guard !closed else { return }
                    drain()
                }
            }

            private func drain() {
                // Yield after four chunks so native cancel/retire callbacks can interleave.
                var budget = 262_144
                let requests = pending
                for request in requests {
                    if request.isCancelled || request.isFinished {
                        remove(request)
                        continue
                    }
                    guard let data = request.dataRequest else {
                        remove(request)
                        request.finishLoading()
                        continue
                    }
                    let offset = max(data.requestedOffset, data.currentOffset)
                    let (end, overflow) = data.requestedOffset.addingReportingOverflow(
                        Int64(data.requestedLength))
                    guard offset >= 0, data.requestedOffset >= 0, data.requestedLength >= 0,
                        data.requestsAllDataToEndOfResource || !overflow
                    else {
                        remove(request)
                        request.finishLoading(with: MonitorAppleProgressiveAssetError.invalidRange)
                        continue
                    }
                    let requestedEnd =
                        data.requestsAllDataToEndOfResource ? length : min(length, end)
                    var cursor = offset
                    do {
                        while budget > 0, cursor < min(available, requestedEnd),
                            !request.isCancelled, !request.isFinished
                        {
                            let count = min(
                                budget, Int(min(65_536, min(available, requestedEnd) - cursor)))
                            try handle.seek(toOffset: UInt64(cursor))
                            guard let bytes = try handle.read(upToCount: count), !bytes.isEmpty
                            else {
                                throw MonitorAppleProgressiveAssetError.incompleteTransfer
                            }
                            guard !request.isCancelled, !request.isFinished else { break }
                            data.respond(with: bytes)
                            cursor += Int64(bytes.count)
                            budget -= bytes.count
                        }
                        if request.isCancelled || request.isFinished {
                            remove(request)
                        } else if cursor >= requestedEnd {
                            remove(request)
                            request.finishLoading()
                        } else if budget == 0, cursor < min(available, requestedEnd) {
                            scheduleDrain()
                        }
                        // Temporary EOF retains this exact request until host publication.
                    } catch {
                        retire(error: error)
                        return
                    }
                }
            }

            private func remove(_ request: AVAssetResourceLoadingRequest) {
                pending.removeAll { $0 === request }
            }

            private func retire(error: any Error) {
                guard !closed else { return }
                closed = true
                let requests = pending
                pending.removeAll()
                for request in requests where !request.isCancelled && !request.isFinished {
                    request.finishLoading(with: error)
                }
                try? handle.close()
                let failure = (error as? MonitorAppleProgressiveAssetError) ?? .sourceUnavailable
                if failure != .retired, let onFailure {
                    Task { @MainActor in onFailure(failure) }
                }
            }
        }
    }
#endif
