import Foundation
@testable import Insta360Apple
import Insta360AppleTestSupport
import Insta360Protocol
import OpenCineCore
import OpenCineMedia
import Testing

/// Controlled transport behind the actual production producer. No socket, camera or sleeps.
@MainActor private final class MediaPort: LunaMediaSourcePort {
    var mediaSourceState: LunaMediaSourceState? = .init(session: .init(), epoch: .init(1), connection: 1)
    var mediaIO: (any LunaMediaIO)?
    var requests: [LunaRequest] = []
    var holdNext: LunaCommand?
    var failNext: LunaCommand?
    var held: CheckedContinuation<Data, Error>?
    var prepared: [MediaBrowseBinding] = []
    var activeBrowse: MediaBrowseBinding?
    func mediaBrowseChanged(_ active: Bool, binding: MediaBrowseBinding, source: LunaMediaSourceState) {
        guard mediaSourceState == source else { return }
        if active { activeBrowse = binding }
        else if activeBrowse == binding { activeBrowse = nil }
    }
    var paths = ["/storage_internal/DCIM/Camera01/VID_20260916_124229_002.mp4"]
    var sdPaths: [String] = []
    var reportedSDState: UInt64? = 1
    var malformedInventory = false
    var failSDList = false
    var holdSDList = false
    var pageSize: Int?
    var repeatFirstPage = false
    var metadataByLocation: [UInt64: Data] = [:]

    func mediaRequest(_ request: LunaRequest, source: LunaMediaSourceState) async throws -> Data {
        guard mediaSourceState == source else { throw MediaServiceError.retired }
        requests.append(request)
        if request.command == failNext {
            failNext = nil; throw URLError(.badServerResponse)
        }
        if request.command == holdNext {
            holdNext = nil
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        if request.command == .getOptions {
            if malformedInventory { return Data([0x80]) }
            let inner = try ProtoMessage.integer(field: 4, value: 2)
            var inventory = try ProtoMessage.blob(field: 176, value: inner)
            if let state = reportedSDState {
                let sd = try ProtoMessage.integer(field: 1, value: state)
                    + ProtoMessage.integer(field: 4, value: 3)
                inventory += try ProtoMessage.blob(field: 176, value: sd)
            }
            return try ProtoMessage.blob(field: 2, value: inventory)
        }
        if request.command == .getFileList {
            let body = try ProtoMessage(request.body)
            let location = try body.unsigned(4)
            if location == 3 {
                if failSDList { throw URLError(.cannotConnectToHost) }
                if holdSDList {
                    holdSDList = false
                    return try await withCheckedThrowingContinuation { held = $0 }
                }
            }
            let bank = location == 2 ? paths : sdPaths
            let start = repeatFirstPage ? 0 : Int(try body.unsigned(2, default: 0))
            let page = bank.dropFirst(start).prefix(pageSize ?? bank.count)
            let uris = try page.reduce(Data()) { try $0 + ProtoMessage.blob(field: 1, value: Data($1.utf8)) }
            return try uris + ProtoMessage.integer(field: 2, value: UInt64(bank.count))
        }
        if request.command == .getFileInfoList {
            let location = try ProtoMessage(request.body).unsigned(1, default: 0)
            return metadataByLocation[location] ?? Data()
        }
        return Data()
    }
    func release(_ response: Data = Data()) { let waiter = held; held = nil; waiter?.resume(returning: response) }
    func prepareMediaReturn(_ binding: MediaBrowseBinding) async { prepared.append(binding) }
    func service() -> LunaMediaService { LunaMediaService(session: mediaSourceState!.session, port: self) }
}

@MainActor private final class MediaIO: LunaMediaIO {
    var held: CheckedContinuation<Void, Never>?
    func jpeg(_ thumbnail: LunaThumbnail) async throws -> Data { Data([1]) }
    func transfer(from url: URL, into sink: any MediaByteSink) async throws -> MediaTransferReceipt {
        await withCheckedContinuation { held = $0 }
        try await sink.write(Data([1]))
        return .init(byteCount: 1)
    }
    func release() { let waiter = held; held = nil; waiter?.resume() }
}

private actor MediaSink: MediaByteSink {
    var chunks: [Data] = []
    func write(_ chunk: Data) { chunks.append(chunk) }
}

// SIMULATED protocol-shaped metadata; the producer must retain the returned path verbatim.
private func mediaInfo(uri: String, size: UInt64) throws -> Data {
    let file = try ProtoMessage.blob(field: 1, value: Data(uri.utf8))
        + ProtoMessage.blob(field: 2, value: ProtoMessage.integer(field: 9, value: size))
    return try ProtoMessage.blob(field: 1, value: file)
}

@MainActor private func mediaLocations(_ requests: [LunaRequest], command: LunaCommand) throws -> [UInt64] {
    try requests.filter { $0.command == command }.map {
        try ProtoMessage($0.body).unsigned(command == .getFileList ? 4 : 1)
    }
}

@MainActor @Suite struct LunaMediaServiceTests {
    @Test func catalogCombinesInternalAndSDWithLocationMetadataAndFullURIIdentity() async throws {
        let port = MediaPort(); port.reportedSDState = 0
        let inner = "/storage_internal/DCIM/Camera01/VID_same.mp4"
        let sd = "/storage_sd/DCIM/Camera01/VID_same.mp4"
        port.paths = [inner]; port.sdPaths = [sd, inner]
        port.metadataByLocation = [2: try mediaInfo(uri: inner, size: 101),
            3: try mediaInfo(uri: sd, size: 202)]
        let service = port.service(); defer { service.retire() }
        let browse = try await service.openBrowse()
        let page = try #require(try await (try await browse.catalog()).next())
        #expect(page.reset && page.complete && page.upserts.count == 2)
        #expect(Set(page.upserts.map(\.id)).count == 2, "same filename on two full paths is not one asset")
        let files = page.upserts.compactMap { service.catalogRecord($0.id, binding: browse.binding)?.file }
        #expect(files.map(\.uri) == [inner, sd])
        #expect(files.map { $0.metadata?.fileSize } == [101, 202])
        #expect(page.upserts.map { $0.representations[0].byteCount } == [101, 202])
        #expect(try mediaLocations(port.requests, command: .getFileList) == [2, 3])
        #expect(try mediaLocations(port.requests, command: .getFileInfoList) == [2, 3])
    }

    @Test func absentSDKeepsInternalAndDoesNotRequestSD() async throws {
        let port = MediaPort(); let service = port.service(); defer { service.retire() }
        let browse = try await service.openBrowse()
        let page = try #require(try await (try await browse.catalog()).next())
        #expect(page.complete && page.upserts.count == 1)
        #expect(try mediaLocations(port.requests, command: .getFileList) == [2])
        #expect(try mediaLocations(port.requests, command: .getFileInfoList) == [2])
    }

    @Test func fullAndWriteProtectedSDRemainReadable() async throws {
        for state in [UInt64(2), UInt64(4)] {
            let port = MediaPort(); port.reportedSDState = state
            port.sdPaths = ["/storage_sd/DCIM/Camera01/IMG_readable.jpg"]
            let service = port.service(); defer { service.retire() }
            let page = try #require(try await (try await (try await service.openBrowse()).catalog()).next())
            #expect(page.complete && page.upserts.count == 2)
            #expect(try mediaLocations(port.requests, command: .getFileList) == [2, 3])
        }
    }

    @Test func unknownOrUnavailableInventoryStillProbesSD() async throws {
        for condition in 0..<3 {
            let port = MediaPort(); port.reportedSDState = nil
            if condition == 1 { port.failNext = .getOptions }
            if condition == 2 { port.malformedInventory = true }
            port.sdPaths = ["/storage_sd/DCIM/Camera01/IMG_unknown_inventory.jpg"]
            let service = port.service(); defer { service.retire() }
            let page = try #require(try await (try await (try await service.openBrowse()).catalog()).next())
            #expect(page.complete && page.upserts.count == 2)
            #expect(try mediaLocations(port.requests, command: .getFileList) == [2, 3])
        }
    }

    @Test func unavailableSDCannotReplaceCommittedCatalog() async throws {
        for inventoryKnown in [true, false] {
            let port = MediaPort(); port.reportedSDState = 0
            port.sdPaths = ["/storage_sd/DCIM/Camera01/IMG_committed.jpg"]
            let service = port.service(); defer { service.retire() }
            let browse = try await service.openBrowse()
            let old = try #require(try await (try await browse.catalog()).next())
            let oldFiles = old.upserts.compactMap { service.catalogRecord($0.id, binding: browse.binding)?.file }
            port.reportedSDState = inventoryKnown ? 0 : nil
            port.paths = ["/storage_internal/DCIM/Camera01/IMG_uncommitted.jpg"]
            port.failSDList = true
            let failed = try await browse.catalog()
            await #expect(throws: URLError.self) { try await failed.next() }
            #expect(old.upserts.compactMap { service.catalogRecord($0.id, binding: browse.binding)?.file } == oldFiles)
        }
    }

    @Test func catalogPagesEachStorageUntilItsAdvertisedTotal() async throws {
        let port = MediaPort(); port.reportedSDState = 0; port.pageSize = 1
        port.paths = ["/storage_internal/DCIM/VID_A.mp4", "/storage_internal/DCIM/LRV_A.lrv", "/storage_internal/DCIM/IMG_A.jpg"]
        port.sdPaths = ["/storage_sd/DCIM/VID_B.mp4", "/storage_sd/DCIM/LRV_B.lrv", "/storage_sd/DCIM/IMG_B.jpg"]
        let service = port.service(); defer { service.retire() }
        let page = try #require(try await (try await (try await service.openBrowse()).catalog()).next())
        #expect(page.complete && page.upserts.count == 4, "raw URI totals include proxy files")
        let requests = port.requests.filter { $0.command == .getFileList }
        let starts = try requests.map { try ProtoMessage($0.body).unsigned(2, default: 0) }
        #expect(starts == [0, 1, 2, 0, 1, 2])
        #expect(try mediaLocations(requests, command: .getFileList) == [2, 2, 2, 3, 3, 3])
    }

    @Test func nonProgressCannotBecomeComplete() async throws {
        let port = MediaPort(); let service = port.service(); defer { service.retire() }
        let browse = try await service.openBrowse()
        let old = try #require(try await (try await browse.catalog()).next())
        port.paths = ["/storage_internal/DCIM/IMG_A.jpg", "/storage_internal/DCIM/IMG_B.jpg"]
        port.pageSize = 1; port.repeatFirstPage = true
        let failed = try await browse.catalog()
        await #expect(throws: MediaServiceError.unavailable) { try await failed.next() }
        #expect(service.catalogRecord(old.upserts[0].id, binding: browse.binding)?.file.uri.contains("VID_") == true)
    }

    @Test func sourceChangesAfterInventoryCannotStartFileList() async throws {
        let port = MediaPort(); let service = port.service(); defer { service.retire() }
        let browse = try await service.openBrowse(); let cursor = try await browse.catalog()
        port.requests.removeAll(); port.holdNext = .getOptions
        let pending = Task { try await cursor.next() }
        #expect(await eventually { port.held != nil })
        port.mediaSourceState = .init(session: browse.binding.session, epoch: browse.binding.epoch.next(), connection: 1)
        port.release()
        await #expect(throws: MediaServiceError.retired) { try await pending.value }
        #expect(port.requests.map(\.command) == [.setAccessCameraFileState, .getOptions])
    }

    @Test func retirementDuringSDQueryCannotPublishOrRequestSDMetadata() async throws {
        let port = MediaPort(); port.reportedSDState = 0; port.holdSDList = true
        let service = port.service(); defer { service.retire() }
        let browse = try await service.openBrowse(); let cursor = try await browse.catalog()
        let pending = Task { try await cursor.next() }
        #expect(await eventually { port.held != nil })
        port.mediaSourceState = .init(session: browse.binding.session, epoch: browse.binding.epoch.next(), connection: 1)
        port.release()
        await #expect(throws: MediaServiceError.retired) { try await pending.value }
        #expect(try mediaLocations(port.requests, command: .getFileList) == [2, 3])
        #expect(try mediaLocations(port.requests, command: .getFileInfoList) == [2])
    }

    @Test func cancelledSDQueryCannotReplaceCommittedCatalog() async throws {
        let port = MediaPort(); let service = port.service(); defer { service.retire() }
        let browse = try await service.openBrowse()
        let old = try #require(try await (try await browse.catalog()).next())
        port.reportedSDState = 0; port.holdSDList = true
        port.paths = ["/storage_internal/DCIM/IMG_uncommitted.jpg"]
        let cursor = try await browse.catalog(); let pending = Task { try await cursor.next() }
        #expect(await eventually { port.held != nil })
        pending.cancel(); port.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(service.catalogRecord(old.upserts[0].id, binding: browse.binding) != nil)
        #expect(try mediaLocations(port.requests, command: .getFileInfoList) == [2, 2])
    }

    @Test func browsePauseIntentIsBoundToCurrentSourceAndLease() async throws {
        let port = MediaPort(); let service = port.service()
        let old = try await service.openBrowse()
        #expect(port.activeBrowse == old.binding)
        let current = try await service.openBrowse()
        await old.close()
        #expect(port.activeBrowse == current.binding, "late A.close cannot unpause B")
        await current.close()
        #expect(port.activeBrowse == nil)
        let replaced = try await service.openBrowse()
        #expect(port.activeBrowse == replaced.binding)
        service.retire()
        #expect(port.activeBrowse == nil)
    }
    @Test func preservationRecordIsBoundToProducingBrowseAndSurvivesReplacement() async throws {
        let port = MediaPort(); let service = port.service()
        let old = try await service.openBrowse()
        let asset = try #require(try await (try await old.catalog()).next()?.upserts.first)
        let captured = try #require(service.catalogRecord( asset.id, binding: old.binding))
        var release: CheckedContinuation<Void, Never>?
        let encoding = Task {
            await withCheckedContinuation { release = $0 }
            return captured.file.uri
        }
        #expect(await eventually { release != nil })
        let current = try await service.openBrowse()
        port.paths = ["/storage_internal/DCIM/Camera01/IMG_successor.jpg"]
        _ = try await (try await current.catalog()).next()
        #expect(service.catalogRecord( asset.id, binding: old.binding) == nil)
        release?.resume()
        #expect(await encoding.value == "/storage_internal/DCIM/Camera01/VID_20260916_124229_002.mp4")
        #expect(captured.asset == asset.id, "encoding owns A's immutable value, not a latest-catalog lookup")
        await current.close()
        #expect(service.catalogRecord( asset.id, binding: current.binding) == nil)
        service.retire()
    }

    @Test func failedCatalogDoesNotCloseMediaOwner() async throws {
        let port = MediaPort(); let service = port.service()
        let browse = try await service.openBrowse()
        let first = try await browse.catalog(); port.failNext = .getFileList
        await #expect(throws: URLError.self) { try await first.next() }
        let next = try await browse.catalog()
        #expect(try await next.next()?.upserts.count == 1)
        #expect(browse.binding.session == service.sessionID)
        service.retire()
    }
    @Test func catalogReplacementRetiresRemovedRepresentationTransfer() async throws {
        let port = MediaPort(); let io = MediaIO(); port.mediaIO = io
        let service = port.service(); let browse = try await service.openBrowse()
        let representation = try #require(try await (try await browse.catalog()).next()?.upserts.first?.representations.first)
        let transfer = try #require(browse.transfers); let sink = MediaSink()
        let old = Task { try await transfer.transfer(representation.id, into: sink) }
        #expect(await eventually { io.held != nil })
        port.paths = ["/storage_internal/DCIM/Camera01/IMG_successor.jpg"]
        _ = try await (try await browse.catalog()).next()
        io.release()
        await #expect(throws: MediaServiceError.retired) { try await old.value }
        #expect(await sink.chunks.isEmpty)
        service.retire()
    }

    @Test func retiredTransferCannotWriteThroughItsNativeSink() async throws {
        let port = MediaPort(); let io = MediaIO(); port.mediaIO = io
        let service = port.service(); let browse = try await service.openBrowse()
        let page = try #require(try await (try await browse.catalog()).next())
        let representation = try #require(page.upserts.first?.representations.first)
        let transfer = try #require(browse.transfers)
        let sink = MediaSink()
        let download = Task { try await transfer.transfer(representation.id, into: sink) }
        #expect(await eventually { io.held != nil })
        port.mediaSourceState = nil
        io.release()
        await #expect(throws: MediaServiceError.retired) { try await download.value }
        #expect(await sink.chunks.isEmpty)
        service.retire()
    }
    @Test func closingOldBrowseAfterReplacementCannotSendAccessOrStart() async throws {
        let port = MediaPort(); let service = port.service()
        let old = try await service.openBrowse()
        port.requests.removeAll(); port.holdNext = .stopLive
        let close = Task { await old.close() }
        #expect(await eventually { port.held != nil })
        let current = try await service.openBrowse()
        port.release()
        await close.value
        #expect(port.requests.map(\.command) == [.stopLive, .stopLive])
        #expect(current.binding != old.binding)
        service.retire()
    }

    @Test func connectionChangeAfterAccessCannotStartNewLive() async throws {
        let port = MediaPort(); let service = port.service()
        let browse = try await service.openBrowse()
        port.requests.removeAll(); port.holdNext = .setAccessCameraFileState
        let close = Task { await browse.close() }
        #expect(await eventually { port.held != nil })
        port.mediaSourceState = .init(session: browse.binding.session, epoch: browse.binding.epoch, connection: 2)
        port.release(); await close.value
        #expect(port.requests.map(\.command) == [.stopLive, .setAccessCameraFileState])
        #expect(port.prepared == [browse.binding])
        await browse.close()
        #expect(port.requests.count == 2, "duplicate close cannot retry return")
        service.retire()
    }

    @Test func epochChangeAfterAlbumAccessCannotListNewSource() async throws {
        let port = MediaPort(); let service = port.service()
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        port.requests.removeAll(); port.holdNext = .setAccessCameraFileState
        let page = Task { try await cursor.next() }
        #expect(await eventually { port.held != nil })
        port.mediaSourceState = .init(session: browse.binding.session, epoch: browse.binding.epoch.next(), connection: 1)
        port.release()
        await #expect(throws: MediaServiceError.retired) { try await page.value }
        #expect(port.requests.map(\.command) == [.setAccessCameraFileState])
        service.retire()
    }

    @Test func replacedCursorRejectsLatePageAndKeepsCurrentListing() async throws {
        let port = MediaPort(); let service = port.service()
        let browse = try await service.openBrowse()
        let previous = try await browse.catalog()
        port.holdNext = .getFileList
        let old = Task { try await previous.next() }
        #expect(await eventually { port.held != nil })
        let current = try await browse.catalog()
        port.paths = ["/storage_internal/DCIM/Camera01/IMG_current.jpg"]
        let page = try #require(try await current.next())
        port.release()
        await #expect(throws: (any Error).self) { try await old.value }
        #expect(page.reset && page.complete && page.upserts.map(\.filename) == ["IMG_current.jpg"])
        #expect(try await current.next() == nil)
        #expect(page.volumes == nil, "the album does not report a storage topology")
        service.retire()
    }

    @Test func actualDeleteAcknowledgesOnlyListedAssetsAndNoSyntheticReadService() async throws {
        let port = MediaPort(); let service = port.service()
        let browse = try await service.openBrowse()
        let page = try #require(try await (try await browse.catalog()).next())
        let asset = try #require(page.upserts.first)
        #expect(browse.thumbnails == nil && browse.transfers == nil)
        #expect(asset.volumeID == nil && asset.capturedAt == nil && asset.pixelSize == nil)
        #expect(asset.representations[0].byteCount == nil && asset.deletable == true)
        let deletion = try #require(browse.deletion)
        port.requests.removeAll()
        let result = try await deletion.delete([asset.id, .init("not-listed")])
        #expect(result.map(\.outcome) == [.accepted, .unsupported])
        #expect(port.requests.map(\.command) == [.deleteFiles])
        #expect(page.removed.isEmpty, "an ACK is not a reported removal")
        await browse.close()
        await #expect(throws: MediaServiceError.retired) { try await deletion.delete([asset.id]) }
        service.retire()
    }

    @Test func actualSessionRejectsMediaReplyFromRetiredEpoch() async throws {
        var sent = 0
        var waiter: CheckedContinuation<Data, Error>?
        let session = LunaCameraSession(send: { _ in
            sent += 1
            return try await withCheckedThrowingContinuation { waiter = $0 }
        }, functionMode: { 7 }, readSettings: {}, readCapture: {})
        session.linkChanged(.streaming, serial: nil)
        let epoch = session.current.epoch
        let reply = Task { try await session.mediaRequest(LunaProtocol.stopLiveRequest, epoch: epoch) }
        #expect(await eventually { waiter != nil })
        session.linkChanged(.streaming, serial: nil)
        waiter?.resume(returning: Data())
        await #expect(throws: CancellationError.self) { try await reply.value }
        await #expect(throws: CancellationError.self) {
            try await session.mediaRequest(LunaProtocol.startLiveRequest, epoch: epoch)
        }
        #expect(sent == 1)
        session.close(.requested)
    }

    @Test func actualConnectionRegistersMediaByProtocolTypeAndRejectsWrongSession() async throws {
        for matching in [true, false] {
            let port = FakeLunaPort()
            let source = MediaPort()
            var made: LunaMediaService?
            port.makeMediaService = { id in
                source.mediaSourceState = .init(session: matching ? id : .init(), epoch: .init(1), connection: 1)
                let service = source.service(); made = service; return service
            }
            let integration = LunaIntegration(port: port)
            let events = integration.connect(.nearby(.init(id: UUID().uuidString, name: "SIMULATED", model: "",
                routes: [.cameraAccessPoint])))
            #expect(await eventually { port.connects.count == 1 })
            port.finishConnect()
            var camera: ConnectedCamera?
            for await case .connected(let connected) in events { camera = connected }
            let connected = try #require(camera)
            let registered = connected.services[(any CameraMediaService).self]
            #expect((registered != nil) == matching)
            #expect(connected.services[LunaMediaService.self] == nil, "lookup is the protocol contract")
            made?.retire(); await connected.session.close(.requested)
        }
    }
}
