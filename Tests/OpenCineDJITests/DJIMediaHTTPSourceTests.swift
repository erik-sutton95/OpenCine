import Foundation
import OpenCineCameraVocabulary
import OpenCineDJI
import OpenCineMedia
import Testing

@MainActor @Suite struct DJIMediaHTTPSourceTests {
    private var file: MediaFile {
        var file = MediaFile(path: "DCIM/DJI_001/a.MP4", thumbPath: "a.scr")
        file.storage = 0; file.sizeBytes = 17
        return file
    }
    @Test func actualRoutingKeepsStorageAndURLIdentities() {
        let source = DJIMediaHTTPSource()
        #expect(source.resources(path: file.path, firstStorage: 0).map(\.storage) == [0, 1])
        #expect(source.resources(path: file.path, firstStorage: 1).map(\.storage) == [1, 0])
        #expect(source.resources(path: file.path, firstStorage: 0).map(\.url) == [
            MediaHTTP.pathURL(storage: 0, path: file.path)!, MediaHTTP.pathURL(storage: 1, path: file.path)!])
        source.rememberStorage(1, path: file.path)
        #expect(source.resolvedStorage(for: file, singleSDStorage: true) == 0)
    }
    @Test func proxyLengthNeverInheritsOriginalSize() {
        let source = DJIMediaHTTPSource()
        let read: @MainActor (DJIMediaHTTPResource, UInt64?, any MediaByteSink) async throws -> MediaTransferReceipt = { _, _, _ in .init(byteCount: 1) }
        let original = source.transferPlan(file: file, path: file.path, singleSDStorage: false, read: read)
        let proxy = source.transferPlan(file: file, path: "a.LRF", singleSDStorage: false, read: read)
        #expect(original.expectedByteCount == 17 && original.attempts.count == 2)
        #expect(proxy.expectedByteCount == nil && proxy.attempts.count == 2)
    }
    @Test func acceptedStorageWinnerAppliesOnlyToSuccessfulPlan() {
        let source = DJIMediaHTTPSource()
        let plan = source.transferPlan(file: file, path: file.path, singleSDStorage: false) { _, _, _ in .init(byteCount: 1) }
        #expect(source.resolvedStorage(for: file, singleSDStorage: false) == 0)
        plan.accepted?(1, .init(byteCount: 1))
        #expect(source.resolvedStorage(for: file, singleSDStorage: false) == 1)
        source.reset()
        #expect(source.resolvedStorage(for: file, singleSDStorage: false) == 0)
    }
    @Test func cancellationAndRetirementNeverRetry() {
        let source = DJIMediaHTTPSource()
        let original = source.transferPlan(file: file, path: file.path, singleSDStorage: false) { _, _, _ in .init(byteCount: 1) }
        let proxy = source.transferPlan(file: file, path: "a.LRF", singleSDStorage: false) { _, _, _ in .init(byteCount: 1) }
        #expect(original.retry(DJIMediaHTTPError.httpStatus(404)))
        #expect(original.retry(DJIMediaHTTPError.httpStatus(403)))
        #expect(!original.retry(DJIMediaHTTPError.httpStatus(500)))
        // Original Swift proxy transport/server fallback differs from Android and is retained.
        #expect(proxy.retry(DJIMediaHTTPError.httpStatus(500)))
        #expect(!proxy.retry(CancellationError()) && !proxy.retry(URLError(.cancelled)))
        #expect(!proxy.retry(MediaServiceError.retired))
    }
    @Test func readReentrySuppressesOutgoingSuccess() async {
        let source = DJIMediaHTTPSource()
        var current = true, requests = 0
        do {
            _ = try await source.read(file: file, path: file.path, singleSDStorage: false,
                ifCurrent: { current }) { _ in requests += 1; current = false; return .init(data: Data([9]), status: 200) }
            Issue.record("Retired source returned bytes")
        } catch { #expect(error as? MediaServiceError == .retired) }
        #expect(requests == 1 && source.resolvedStorage(for: file, singleSDStorage: false) == 0)
    }
}
