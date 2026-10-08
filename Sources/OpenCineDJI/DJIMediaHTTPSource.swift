import Foundation
import OpenCineCameraVocabulary
import OpenCineMedia

public enum DJIMediaHTTPError: Error { case badResponse, httpStatus(Int), timeout }
public struct DJIMediaHTTPResource: Sendable {
    public let storage: Int
    public let url: URL
}
public struct DJIMediaHTTPPayload: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}

/// One source's raw storage routing. UI/library owners never decode handle bits or choose a
/// storage retry. Actual byte IO arrives through the platform's bounded native stream port.
@MainActor public final class DJIMediaHTTPSource {
    private var winners: [String: Int] = [:]
    public init() {}
    public func reset() { winners.removeAll() }
    public func resolvedStorage(for file: MediaFile, singleSDStorage: Bool) -> Int {
        MediaHTTP.resolvedStorage(stamped: file.storage,
            handle: file.handle != 0 ? file.handle : file.cmdHandle,
            winner: winners[file.path], singleSdStorage: singleSDStorage)
    }
    public func rememberStorage(_ storage: Int, path: String) { winners[path] = storage }
    public func resources(path: String, firstStorage: Int) -> [DJIMediaHTTPResource] {
        [firstStorage, firstStorage == 0 ? 1 : 0].compactMap { storage in
            MediaHTTP.pathURL(storage: storage, path: path).map { .init(storage: storage, url: $0) }
        }
    }
    public func transferPlan(file: MediaFile, path: String, singleSDStorage: Bool,
        read: @escaping @MainActor (DJIMediaHTTPResource, UInt64?, any MediaByteSink) async throws -> MediaTransferReceipt)
        -> MediaTransferPlan {
        let resources = resources(path: path, firstStorage: resolvedStorage(for: file, singleSDStorage: singleSDStorage))
        let expected = path == file.path && file.sizeBytes > 0 ? file.sizeBytes : nil
        return .init(expectedByteCount: expected, attempts: resources.map { resource in
            { sink in try await read(resource, expected, sink) }
        }, retry: { error in
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            if let failure = error as? MediaServiceError, failure == .retired { return false }
            if case DJIMediaHTTPError.httpStatus(let code) = error {
                return code == 404 || (400...499).contains(code) || MediaHTTP.isProxyPath(path)
            }
            return MediaHTTP.isProxyPath(path)
        }, accepted: { [weak self] index, _ in self?.winners[file.path] = resources[index].storage })
    }
    public func read(file: MediaFile, path: String, singleSDStorage: Bool,
        ifCurrent: @escaping @MainActor () -> Bool,
        get: @escaping @MainActor (DJIMediaHTTPResource) async throws -> DJIMediaHTTPPayload) async throws -> Data {
        var lastError: any Error = DJIMediaHTTPError.badResponse
        for resource in resources(path: path, firstStorage: resolvedStorage(for: file, singleSDStorage: singleSDStorage)) {
            try Task.checkCancellation()
            guard ifCurrent() else { throw MediaServiceError.retired }
            do {
                let response = try await get(resource)
                guard ifCurrent(), !Task.isCancelled else { throw MediaServiceError.retired }
                if (200...299).contains(response.status) {
                    winners[file.path] = resource.storage
                    return response.data
                }
                lastError = DJIMediaHTTPError.httpStatus(response.status)
            } catch {
                try Task.checkCancellation()
                guard ifCurrent() else { throw MediaServiceError.retired }
                lastError = error
            }
        }
        throw lastError
    }
}
