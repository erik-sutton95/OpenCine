import Foundation
import OpenCineCore
import OpenCineMedia
import OpenCineNikon
import Testing

@MainActor @Suite("SIMULATED Nikon real catalog producer")
struct NikonMediaServiceTests {
    @Test func firstPageResetRetiresOldRawCatalogWhileSubsequentPagesAccumulate() async throws {
        let io = MediaIOFixture()
        let clock = CatalogClock()
        let firstObject = io.record(1, 4, "FIRST.MOV")
        let secondObject = io.record(1, 5, "SECOND.MOV")
        io.objects = [firstObject.location: firstObject, secondObject.location: secondObject]
        io.snapshot = .init(
            handles: [firstObject.location, secondObject.location],
            authoritativeStorages: [1], storageListAuthoritative: true)
        io.onObject = { clock.advance(.milliseconds(120)) }
        let source = NikonMediaService(session: io.session, io: io, now: { clock.read() })
        source.configure(.init(cached: [], category: .all))
        let browse = try await source.openBrowse()
        let cursor = try await browse.catalog()
        let first = try #require(try await cursor.next())
        let second = try #require(try await cursor.next())
        #expect(first.reset)
        #expect(!second.reset)
        #expect(first.upserts.count == 1 && second.upserts.count == 1)
        let stale = io.record(1, 6, "STALE.MOV").asset(namespace: io.cameraNamespace)
        let afterFirst = MediaCatalog(assets: [stale]).applying(first)
        #expect(afterFirst.assets.map(\.id) == first.upserts.map(\.id))
        let afterSecond = afterFirst.applying(second)
        #expect(
            Set(afterSecond.assets.map(\.id)) == Set((first.upserts + second.upserts).map(\.id)))
        cursor.close()
        io.snapshot = .init(handles: [], authoritativeStorages: [1], storageListAuthoritative: true)
        let empty = try #require(try await browse.catalog().next())
        #expect(empty.reset && empty.complete && empty.upserts.isEmpty)
        #expect(afterSecond.applying(empty).assets.isEmpty)
        await browse.close()
    }

    @Test func failedCardCannotTombstoneOrClaimCompleteWhileConfirmedEmptyCardCan() async throws {
        let io = MediaIOFixture()
        let empty = io.record(1, 4, "EMPTY-OLD.MOV")
        let failed = io.record(2, 4, "FAILED-OLD.MOV")
        io.snapshot = .init(
            handles: [], authoritativeStorages: [1], failedStorages: [2],
            storageListAuthoritative: true)
        let service = io.service()
        service.configure(.init(cached: [empty, failed], category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let removal = try #require(try await cursor.next())
        #expect(removal.removed == [empty.asset(namespace: io.cameraNamespace).id])
        #expect(!removal.complete)
        let final = try #require(try await cursor.next())
        #expect(!final.complete)
        #expect(final.removed.isEmpty)
        do {
            _ = try await cursor.next()
            Issue.record("Failed card claimed a complete cursor")
        } catch { #expect(error as? MediaServiceError == .unavailable) }
        #expect(service.coveredCategory == nil)
        #expect(io.objectCalls.isEmpty)
    }

    @Test func recycledSizeDrainsOldIdentityBeforeInstallingReplacement() async throws {
        let io = MediaIOFixture()
        let old = io.record(1, 7, "A.MOV", size: 100)
        let new = io.record(1, 7, "A.MOV", size: 200)
        io.snapshot = .init(
            handles: [new.location], authoritativeStorages: [1], storageListAuthoritative: true)
        io.objects[new.location] = new
        let service = io.service()
        service.configure(.init(cached: [old], category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let removed = try #require(try await cursor.next())
        #expect(removed.upserts.isEmpty)
        #expect(removed.removed == [old.asset(namespace: io.cameraNamespace).id])
        #expect(
            service.mediaCatalogRecord(removed.removed[0], binding: browse.binding)?.object == old)
        let page = try #require(try await cursor.next())
        #expect(page.upserts.map(\.id) == [new.asset(namespace: io.cameraNamespace).id])
        #expect(page.upserts[0].id != removed.removed[0])
        #expect(page.complete)
        #expect(service.coveredCategory == .all)
        #expect(io.objectCalls == [new.location, new.location])
    }

    @Test func scopedMetadataNeverDeletesCachedOffTabAndIgnoredFormatLearnsThenSkips() async throws
    {
        let io = MediaIOFixture()
        let cached = io.record(1, 1, "OLD.JPG")
        let video = io.record(1, 3, "NEW.MOV")
        let photo = io.record(1, 2, "NEW.JPG")
        io.objects = [cached.location: cached, video.location: video, photo.location: photo]
        io.snapshot = .init(
            handles: [cached.location, video.location, photo.location], authoritativeStorages: [1],
            storageListAuthoritative: true)
        // Body ignores the format: preserve donor fallback.
        io.formats = { _ in io.snapshot.handles }
        let service = io.service()
        service.configure(.init(cached: [cached], category: .videos, identityProbeBudget: 0))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        #expect(page.removed.isEmpty)
        #expect(Set(page.upserts.map(\.filename)) == ["NEW.MOV", "NEW.JPG"])
        #expect(service.listedCount == 1)
        #expect(service.coveredCategory == .videos)
        #expect(!io.objectCalls.contains(cached.location))
        #expect(io.formatCalls == [MediaObjectFormats.video, MediaObjectFormats.photo])
    }

    @Test
    func actualNativeIdentityReplacementInsideObjectReadRefusesPublicationAndPreservesSuccessor()
        async throws
    {
        let io = MediaIOFixture()
        let object = io.record(1, 3, "A.MOV")
        io.objects[object.location] = object
        io.snapshot = .init(
            handles: [object.location], authoritativeStorages: [1], storageListAuthoritative: true)
        let service = io.service()
        service.configure(.init(cached: [], category: .all))
        let old = try await service.openBrowse()
        let cursor = try await old.catalog()
        io.onObject = { io.replaceNative() }
        do {
            _ = try await cursor.next()
            Issue.record("Retired native object published")
        } catch { #expect(error as? MediaServiceError == .retired) }
        #expect(service.listedCount == 0)
        io.onObject = nil
        let next = try await service.openBrowse()
        let nextCursor = try await next.catalog()
        await old.close()
        let page = try #require(try await nextCursor.next())
        #expect(page.upserts.map(\.filename) == ["A.MOV"])
        #expect(page.complete)
        #expect(service.isCurrent(next.binding))
        #expect(io.objectCalls == [object.location, object.location])
    }

    @Test func replacedCursorCannotPublishOrCloseSuccessorWithinSameBrowse() async throws {
        let io = MediaIOFixture()
        let object = io.record(1, 4, "A.MOV")
        io.objects[object.location] = object
        io.snapshot = .init(
            handles: [object.location], authoritativeStorages: [1], storageListAuthoritative: true)
        let service = io.service()
        service.configure(.init(cached: [], category: .all))
        let browse = try await service.openBrowse()
        let old = try await browse.catalog()
        var successor: (any MediaCatalogCursor)?
        io.onObjectAsync = {
            io.onObjectAsync = nil
            successor = try await browse.catalog()
        }
        do {
            _ = try await old.next()
            Issue.record("Retired cursor published")
        } catch { #expect(error as? MediaServiceError == .retired) }
        old.close()
        let page = try #require(try await successor?.next())
        #expect(page.upserts.map(\.filename) == ["A.MOV"])
        #expect(page.complete)
        #expect(io.objectCalls == [object.location, object.location])
    }

    @Test func manualClockSuppliesBoundedPagesWithoutSleep() async throws {
        let io = MediaIOFixture()
        let clock = CatalogClock()
        let records = (1...5).map { io.record(1, UInt32($0), "\($0).MOV") }
        io.objects = Dictionary(uniqueKeysWithValues: records.map { ($0.location, $0) })
        io.snapshot = .init(
            handles: records.map(\.location), authoritativeStorages: [1],
            storageListAuthoritative: true)
        io.onObject = { clock.advance(.milliseconds(60)) }
        let service = NikonMediaService(session: io.session, io: io, now: { clock.read() })
        service.configure(.init(cached: [], category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let first = try #require(try await cursor.next())
        let second = try #require(try await cursor.next())
        let third = try #require(try await cursor.next())
        let pageSizes: [Int] = [first.upserts.count, second.upserts.count, third.upserts.count]
        #expect(pageSizes == [2, 2, 1])
        #expect(!first.complete && !second.complete && third.complete)
        #expect(io.objectCalls.count == 5)
    }

    @Test func actualHeaderReadBackfillsAlreadyPublishedProxyWithoutChangingContentIdentity()
        async throws
    {
        let io = MediaIOFixture()
        let proxy = io.record(1, 9, "A.MOV")
        let master = io.record(1, 8, "A.R3D")
        io.objects = [proxy.location: proxy, master.location: master]
        io.snapshot = .init(
            handles: [proxy.location, master.location], authoritativeStorages: [1],
            storageListAuthoritative: true)
        var header = [UInt8](repeating: 0, count: 60)
        header.replaceSubrange(4..<8, with: [0x52, 0x45, 0x44, 0x31])
        header.replaceSubrange(52..<56, with: [0, 0, 0x17, 0xA0])
        header.replaceSubrange(56..<60, with: [0, 0, 0x0D, 0x4A])
        io.headers[master.location] = Data(header)
        let clock = CatalogClock()
        io.onObject = { clock.advance(.milliseconds(120)) }
        let service = NikonMediaService(session: io.session, io: io, now: { clock.read() })
        service.configure(.init(cached: [], category: .all))
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let first = try #require(try await cursor.next())
        #expect(first.upserts.map(\.filename) == ["A.MOV"])
        let second = try #require(try await cursor.next())
        let updated = try #require(second.upserts.first { $0.filename == "A.MOV" })
        #expect(updated.id == first.upserts[0].id)
        let captured = try #require(service.mediaCatalogRecord(updated.id, binding: browse.binding))
        #expect(captured.object.sourcePixelWidth == 6048)
        #expect(captured.object.sourcePixelHeight == 3402)
        #expect(captured.object.linkedR3DFilename == "A.R3D")
        #expect(io.headerCalls == [master.location])
    }

    @Test func confirmedNoStoragesPublishesKnownEmptyVolumesAndCompletion() async throws {
        let io = MediaIOFixture()
        let service = io.service()
        let browse = try await service.openBrowse()
        let page = try #require(try await browse.catalog().next())
        #expect(page.complete && page.upserts.isEmpty && page.removed.isEmpty)
        #expect(page.volumes == [])
        #expect(service.coveredCategory == .all)
        #expect(io.objectCalls.isEmpty && io.formatCalls.isEmpty)
    }

    @Test func authoritativeMissingAndEmptyCardsRetireCachedContentButUnknownDiscoveryCannot()
        async throws
    {
        for storages: Set<UInt32> in [[1], []] {
            let io = MediaIOFixture()
            let old = io.record(2, 7, "ABSENT.MOV")
            io.snapshot = .init(
                handles: [], authoritativeStorages: storages, storageListAuthoritative: true)
            let service = io.service()
            service.configure(.init(cached: [old], category: .all))
            let browse = try await service.openBrowse()
            let cursor = try await browse.catalog()
            let removed = try #require(try await cursor.next())
            #expect(removed.removed == [old.asset(namespace: io.cameraNamespace).id])
            #expect(!removed.complete)
            let complete = try #require(try await cursor.next())
            #expect(complete.complete && complete.upserts.isEmpty)
            #expect(service.coveredCategory == .all)
            #expect(io.objectCalls.isEmpty)
        }
        let io = MediaIOFixture()
        let old = io.record(2, 7, "UNKNOWN.MOV")
        io.snapshot = .init(handles: [], authoritativeStorages: [], storageListAuthoritative: false)
        let service = io.service()
        service.configure(.init(cached: [old], category: .all))
        let browse = try await service.openBrowse()
        let page = try #require(try await browse.catalog().next())
        #expect(page.removed.isEmpty && !page.complete && page.volumes == nil)
        #expect(service.coveredCategory == nil)
    }

    @Test func captureInvalidationRetiresOnlyCoverageWithoutChangingBrowseOrIssuingIO() async throws
    {
        let io = MediaIOFixture()
        let service = io.service()
        let browse = try await service.openBrowse()
        _ = try await browse.catalog().next()
        #expect(service.coveredCategory == .all)
        service.invalidateCatalogCoverage()
        #expect(service.coveredCategory == nil && service.isCurrent(browse.binding))
        #expect(io.objectCalls.isEmpty && io.storageCalls == 0)
    }

    @Test func appearanceStorageRefreshKeepsExistingLeaseAndCategoryPassesDoNotAddReads()
        async throws
    {
        let io = MediaIOFixture()
        let service = io.service()
        let info = try #require(PTPStorageInfo([UInt8](repeating: 0, count: 22)))
        io.storageRecords = [.init(id: 1, info: info)]
        // Local gallery appearance has no catalog lease; it still performs the original read.
        try await service.refreshStorage()
        #expect(io.storageCalls == 1 && service.storageRecords == io.storageRecords)
        let browse = try await service.openBrowse()
        _ = try await browse.catalog().next()
        _ = try await browse.catalog().next()
        #expect(io.storageCalls == 1)
        try await service.refreshStorage()
        #expect(io.storageCalls == 2 && service.isCurrent(browse.binding))
        io.onStorage = { io.replaceNative() }
        do {
            try await service.refreshStorage()
            Issue.record("Retired storage source published")
        } catch { #expect(error as? MediaServiceError == .retired) }
        #expect(io.storageCalls == 3)
        let successor = try await service.openBrowse()
        io.onStorage = nil
        try await service.refreshStorage()
        #expect(io.storageCalls == 4 && service.isCurrent(successor.binding))
        await successor.close()
        try await service.refreshStorage()
        #expect(io.storageCalls == 5 && service.storageRecords == io.storageRecords)
        #expect(!service.isCurrent(successor.binding))
    }

    @Test func newEpochAndPendingAppearanceCannotExposeOrOverwriteOldCapacityFacts() async throws {
        let io = MediaIOFixture()
        let service = io.service()
        var bytes = [UInt8](repeating: 0, count: 22)
        bytes[14] = 7
        let oldInfo = try #require(PTPStorageInfo(bytes))
        io.storageRecords = [.init(id: 1, info: oldInfo)]
        let object = io.record(1, 9, "A.MOV")
        io.objects[object.location] = object
        io.snapshot = .init(
            handles: [object.location], authoritativeStorages: [1], storageListAuthoritative: true)
        try await service.refreshStorage()
        let old = try await service.openBrowse()
        let oldPage = try #require(try await old.catalog().next())
        #expect(oldPage.volumes?.first?.freeBytes.value == 7)
        io.replaceNative()
        #expect(service.storageRecords.isEmpty)
        let successor = try await service.openBrowse()
        let unknown = try #require(try await successor.catalog().next())
        #expect(unknown.volumes == nil)
        var pendingPage: MediaCatalogDelta?
        io.onStorageAsync = {
            io.onStorageAsync = nil
            #expect(service.storageRecords.isEmpty)
            pendingPage = try await successor.catalog().next()
            // A newer appearance completes first on this exact source; old completion cannot win.
            var fresh = [UInt8](repeating: 0, count: 22)
            fresh[14] = 11
            let info = try #require(PTPStorageInfo(fresh))
            io.storageRecords = [.init(id: 1, info: info)]
            try await service.refreshStorage()
        }
        do {
            try await service.refreshStorage()
            Issue.record("Superseded storage read published")
        } catch { #expect(error as? MediaServiceError == .retired) }
        #expect(pendingPage?.volumes == nil)
        #expect(service.storageRecords.first?.info.freeSpaceBytes == 11)
        let accepted = try #require(try await successor.catalog().next())
        #expect(accepted.volumes?.first?.freeBytes.value == 11)
        #expect(io.storageCalls == 3 && service.isCurrent(successor.binding))
        await old.close()
        #expect(service.isCurrent(successor.binding))
    }

    @Test func locationIndependentPairingIsAcceptedOnlyByItsExactCurrentBrowse() async throws {
        let io = MediaIOFixture()
        let master = io.record(1, 8, "A.R3D")
        io.objects[master.location] = master
        io.snapshot = .init(
            handles: [master.location], authoritativeStorages: [1], storageListAuthoritative: true)
        var header = [UInt8](repeating: 0, count: 60)
        header.replaceSubrange(4..<8, with: [0x52, 0x45, 0x44, 0x31])
        header.replaceSubrange(52..<56, with: [0, 0, 0x17, 0xA0])
        header.replaceSubrange(56..<60, with: [0, 0, 0x0D, 0x4A])
        io.headers[master.location] = Data(header)
        let local = NikonMediaPairingRecord(
            filename: "A.MOV", captureDate: "local-civil-date", sizeBytes: 4)
        let service = io.service()
        service.configure(.init(cached: [], pairing: [local], category: .all))
        let old = try await service.openBrowse()
        let page = try #require(try await old.catalog().next())
        #expect(page.upserts.map(\.filename) == ["A.R3D"])
        #expect(page.upserts.allSatisfy { $0.volumeID == "1" })
        let updates = try #require(service.mediaPairingUpdates(binding: old.binding))
        #expect(
            updates == [.init(previous: local, width: 6048, height: 3402, masterFilename: "A.R3D")])
        let successor = try await service.openBrowse()
        #expect(service.mediaPairingUpdates(binding: old.binding) == nil)
        #expect(service.mediaPairingUpdates(binding: successor.binding) == [])
        await old.close()
        let next = try #require(try await successor.catalog().next())
        #expect(next.complete)
        #expect(service.mediaPairingUpdates(binding: successor.binding) == updates)
        #expect(io.headerCalls == [master.location, master.location])
    }

    @Test func downloadedLocationlessMasterParticipatesInFallbackButRemovedRemoteMetadataCannot()
        async throws
    {
        for retained in [true, false] {
            let io = MediaIOFixture()
            let proxy = io.record(1, 9, "A.MOV")
            io.objects[proxy.location] = proxy
            io.snapshot = .init(
                handles: [], authoritativeStorages: [1], storageListAuthoritative: true)
            io.formats = { $0 == MediaObjectFormats.video ? [proxy.location] : [] }
            let local = NikonMediaPairingRecord(
                filename: "A.R3D", captureDate: "20261004T120000",
                sizeBytes: 4, pixelWidth: 6048, pixelHeight: 3402)
            let service = io.service()
            service.configure(
                .init(
                    cached: [], pairing: [local], category: .photos,
                    retainedLocalFilenames: retained ? ["A.R3D"] : []))
            let browse = try await service.openBrowse()
            let page = try #require(try await browse.catalog().next())
            #expect(page.complete)
            if retained {
                #expect(io.formatCalls == [MediaObjectFormats.video])
                #expect(io.objectCalls == [proxy.location])
                let asset = try #require(page.upserts.first)
                let record = try #require(
                    service.mediaCatalogRecord(asset.id, binding: browse.binding))
                #expect(
                    record.object.sourcePixelWidth == 6048
                        && record.object.sourcePixelHeight == 3402)
                #expect(record.object.linkedR3DFilename == "A.R3D")
            } else {
                #expect(page.upserts.isEmpty && io.formatCalls.isEmpty && io.objectCalls.isEmpty)
            }
            #expect(io.headerCalls.isEmpty)
        }
    }

    @Test func unicodeTwoCardsAndUnknownFactsRemainDistinct() {
        let io = MediaIOFixture()
        let a = io.record(1, 8, "Scene Göteborg.MOV", size: 0)
        let b = io.record(2, 8, "Scene Göteborg.MOV", size: 0xFFFF_FFFF)
        let first = a.asset(namespace: io.cameraNamespace)
        let second = b.asset(namespace: io.cameraNamespace)
        #expect(first.id != second.id)
        #expect(first.representations[0].byteCount == nil)
        #expect(second.representations[0].byteCount == nil)
        #expect(first.capturedAt == nil && first.pixelSize == nil && first.deletable == nil)
    }
}

@MainActor private final class MediaIOFixture: NikonMediaIO {
    let session = CameraSessionID()
    let cameraNamespace = "SIMULATED-camera"
    private var native = NSObject()
    private var retainedNative: [NSObject] = []
    private var epoch = ControlEpoch(1)
    var sourceIdentity: NikonMediaSourceIdentity? {
        .init(native: ObjectIdentifier(native), session: session, epoch: epoch)
    }
    var snapshot = NikonMediaHandleSnapshot(
        handles: [], authoritativeStorages: [], storageListAuthoritative: true)
    var objects: [MediaObjectHandle: NikonMediaObjectRecord] = [:]
    var objectCalls: [MediaObjectHandle] = []
    var storageCalls = 0
    var storageRecords: [NikonMediaStorageRecord] = []
    var onStorage: (() -> Void)?
    var onStorageAsync: (() async throws -> Void)?
    var headers: [MediaObjectHandle: Data] = [:]
    var headerCalls: [MediaObjectHandle] = []
    var formatCalls: [[UInt32]] = []
    var formats: (([UInt32]) -> [MediaObjectHandle])?
    var onObject: (() -> Void)?
    var onObjectAsync: (() async throws -> Void)?
    func service() -> NikonMediaService { .init(session: session, io: self) }
    func replaceNative() {
        retainedNative.append(native)
        native = NSObject()
        epoch = epoch.next()
    }
    func record(_ storage: UInt32, _ handle: UInt32, _ filename: String, size: UInt64 = 10)
        -> NikonMediaObjectRecord
    {
        .init(
            location: .init(storageID: storage, handle: handle), filename: filename,
            captureDate: "20261004T120000", sizeBytes: size)
    }
    func storage(source _: NikonMediaSourceIdentity) async throws -> [NikonMediaStorageRecord] {
        storageCalls += 1
        let captured = storageRecords
        onStorage?()
        try await onStorageAsync?()
        return captured
    }
    func handles(source _: NikonMediaSourceIdentity) async throws -> NikonMediaHandleSnapshot {
        snapshot
    }
    func handles(formats: [UInt32], source _: NikonMediaSourceIdentity) async throws
        -> [MediaObjectHandle]
    {
        formatCalls.append(formats)
        return self.formats?(formats) ?? []
    }
    func object(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> NikonMediaObjectRecord?
    {
        objectCalls.append(location)
        onObject?()
        try await onObjectAsync?()
        return objects[location]
    }
    func header(_ location: MediaObjectHandle, source _: NikonMediaSourceIdentity) async throws
        -> Data?
    {
        headerCalls.append(location)
        return headers[location]
    }
}

private final class CatalogClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Duration = .zero
    func advance(_ delta: Duration) {
        lock.lock()
        defer { lock.unlock() }
        value += delta
    }
    func read() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
