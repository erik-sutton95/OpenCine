import Foundation
import OpenCineCore
import OpenCineDJI
import OpenCineDJIApple
import OpenCineMedia
import Testing

/// SIMULATED primitive wire input and a manual monotonic clock, never native readiness.
@MainActor private final class MediaClock {
    var now: TimeInterval = 0
    var delays: [Duration] = []
    var pauseNext = false
    var paused: CheckedContinuation<Void, Never>?
    var timing: DjiAppleMediaTiming {
        .init(
            now: { self.now },
            sleep: { delay in
                try Task.checkCancellation()
                self.delays.append(delay)
                let parts = delay.components
                self.now += Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                if self.pauseNext {
                    self.pauseNext = false
                    await withCheckedContinuation { self.paused = $0 }
                } else {
                    await Task.yield()
                }
                try Task.checkCancellation()
            })
    }
    func release() {
        let value = paused
        paused = nil
        value?.resume()
    }
}

@MainActor private final class MediaPeer: DjiAppleMediaMutationPort {
    let session = CameraSessionID()
    var mediaFacts: DjiAppleMediaFacts?
    let ingress = DjiAppleMediaIngressSlot()
    weak var service: DjiAppleMediaService?
    var writes: [Duml.Frame] = []
    var entries = 0
    var enterSuccess = true
    var admissions: [Bool] = []
    var returns = 0
    var exits = 0
    var enables = 0
    var completions: [DjiAppleMediaLiveReturn.Result] = []
    var inject = true
    var manifest = true
    var transformManifest: ((Data) throws -> Data)?
    var wireHeld: [Bool] = []
    var ticket: DjiAppleMediaIngress?
    var retiredTicket: DjiAppleMediaIngress?
    var mutationWrites: [(Duml.Frame, Duration)] = []
    var mutationReply: [UInt8] = [0]
    var mutationHook: (() async throws -> Void)?

    init(gallery: Bool = false) {
        mediaFacts = .init(
            identity: .init(session: session, epoch: .init(1), cameraID: "SIMULATED-camera"),
            canQuery: true, bodyGalleryOpen: gallery, inPlayback: false)
    }
    func mediaBrowseChanged(
        _ active: Bool, binding: MediaBrowseBinding, source: DjiAppleMediaIdentity
    ) {
        admissions.append(active)
    }
    func enterMediaPlayback(source: DjiAppleMediaIdentity, timeout: Duration) async throws
        -> Duml.Frame
    {
        #expect(timeout == .milliseconds(900))
        #expect(mediaFacts?.identity == source)
        entries += 1
        return frame([enterSuccess ? 0 : 0xe0])
    }
    func setMediaWireHeld(_ held: Bool, source: DjiAppleMediaIdentity) {
        #expect(mediaFacts?.identity == source)
        wireHeld.append(held)
    }
    func writeMedia(_ frame: Duml.Frame, source: DjiAppleMediaIdentity) throws {
        #expect(mediaFacts?.identity == source)
        writes.append(frame)
        // This models the raw receive callback capturing before actor queueing.
        ticket = ingress.capture()
        if let retiredTicket {
            #expect(
                service?.ingest(
                    self.frame([0x4a, 3, 0, 0, 1, 0, 0, 0, 0, 0]), admission: retiredTicket)
                    == false)
        }
        guard inject, let ticket else { return }
        let counter = frame.payload[4]
        if frame.payload[1] == 4 { return }
        let header: [UInt8] = [0x4a, 4, 0, 0, counter, 0, 0, 0, 0, 0]
        #expect(service?.ingest(self.frame(header), admission: ticket) == true)
        if manifest, counter == MediaListCommand.internalCounter {
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(
                    "OpenCineDJITests/Fixtures/nano-manifest.bin")
            let original = try Data(contentsOf: fixture)
            let data = try transformManifest?(original) ?? original
            #expect(
                service?.ingest(
                    self.frame([0x4a, 1, 0, 0, counter, 0, 0, 0, 0, 0] + [UInt8](data)),
                    admission: ticket) == true)
        }
        #expect(
            service?.ingest(self.frame([0x4a, 3, 0, 0, counter, 0, 0, 0, 0, 0]), admission: ticket)
                == true)
    }
    func claimMediaReturn(
        binding: MediaBrowseBinding, source: DjiAppleMediaIdentity,
        operation: @escaping @MainActor (DjiAppleMediaReturnAuthority) async -> Void
    ) async {
        returns += 1
        await operation(
            .init(
                isCurrent: { self.mediaFacts?.identity.session == source.session },
                inPlayback: { false }, pictureFresh: { self.enables == 1 },
                exitPlayback: {
                    self.exits += 1
                    return true
                },
                enableLiveView: {
                    self.enables += 1
                    return true
                },
                completed: { self.completions.append($0) }))
    }
    func requestMedia(_ frame: Duml.Frame, source: DjiAppleMediaIdentity, timeout: Duration)
        async throws -> Duml.Frame {
        #expect(mediaFacts?.identity == source)
        mutationWrites.append((frame, timeout))
        try await mutationHook?()
        return .init(sender: frame.receiver, receiver: frame.sender, seq: frame.seq,
            flags: Duml.flagResponse, cmdSet: frame.cmdSet, cmdId: frame.cmdId,
            payload: mutationReply)
    }
    func frame(_ payload: [UInt8]) -> Duml.Frame {
        .init(
            sender: 1, receiver: 0, seq: 0, flags: Duml.flagResponse,
            cmdSet: 0, cmdId: 0x27, payload: payload)
    }
}

@MainActor @Suite struct DjiAppleMediaServiceTests {
    private func owner(_ peer: MediaPeer, _ clock: MediaClock) -> DjiAppleMediaService {
        let owner = DjiAppleMediaService(
            session: peer.session, port: peer,
            timing: clock.timing, ingress: peer.ingress)
        peer.service = owner
        return owner
    }

    @Test func actualCatalogMutationKeepsWireBytesTimeoutsAndCameraAcknowledgement() async throws {
        let peer = MediaPeer(), clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        let asset = try #require(page.upserts.first {
            service.mediaCatalogRecord($0.id, binding: browse.binding)?.file.isDeletable == true
        })
        let file = try #require(service.mediaCatalogRecord(asset.id, binding: browse.binding)?.file)
        try await service.setFavorite(asset.id, on: true, binding: browse.binding)
        let deleted = try await service.deleteAsset(asset.id, binding: browse.binding)
        #expect(deleted)
        #expect(peer.mutationWrites.count == 2)
        #expect(peer.mutationWrites[0].0 == Commands.setMediaFavorite(handle: file.favoriteHandle, on: true, counter: 1))
        #expect(peer.mutationWrites[0].1 == .milliseconds(900))
        #expect(peer.mutationWrites[1].0 == Commands.deleteMedia(handle: file.handle, counter: 2))
        #expect(peer.mutationWrites[1].1 == .seconds(2))
        #expect(service.mediaCatalogRecord(asset.id, binding: browse.binding) != nil)
        service.retire()
    }

    @Test func failedCameraReplyDoesNotBecomeAcceptedDeletion() async throws {
        let peer = MediaPeer(), clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        let asset = try #require(page.upserts.first {
            service.mediaCatalogRecord($0.id, binding: browse.binding)?.file.isDeletable == true
        })
        peer.mutationReply = [0xe0]
        #expect(try await service.deleteAsset(asset.id, binding: browse.binding) == false)
        #expect(service.mediaCatalogRecord(asset.id, binding: browse.binding) != nil)
        service.retire()
    }

    @Test func unknownAssetAndRetiredConnectionCannotWriteAMutation() async throws {
        let peer = MediaPeer(), clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        await #expect(throws: MediaServiceError.unavailable) {
            try await service.setFavorite(.init("unknown"), on: true, binding: browse.binding)
        }
        let facts = try #require(peer.mediaFacts)
        peer.mediaFacts = .init(identity: .init(session: facts.identity.session,
            epoch: .init(2), cameraID: facts.identity.cameraID), canQuery: true,
            bodyGalleryOpen: false, inPlayback: true)
        await #expect(throws: MediaServiceError.retired) {
            try await service.deleteAsset(page.upserts[0].id, binding: browse.binding)
        }
        #expect(peer.mutationWrites.isEmpty)
        service.retire()
    }

    @Test func replyAfterReentrantRetirementCannotAcceptTheOldMutation() async throws {
        let peer = MediaPeer(), clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        let asset = try #require(page.upserts.first {
            service.mediaCatalogRecord($0.id, binding: browse.binding)?.file.isDeletable == true
        })
        peer.mutationHook = { service.retire() }
        await #expect(throws: MediaServiceError.retired) {
            try await service.deleteAsset(asset.id, binding: browse.binding)
        }
        #expect(peer.mutationWrites.count == 1)
        #expect(service.mediaCatalogRecord(asset.id, binding: browse.binding) == nil)
    }

    @Test func bodyGallerySendsNoEnterOrListAndKeepsSafeReturn() async throws {
        let peer = MediaPeer(gallery: true)
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        #expect(try await cursor.next() == nil)
        #expect(peer.entries == 0 && peer.writes.isEmpty)
        #expect(browse.thumbnails == nil && browse.transfers == nil && browse.deletion == nil)
        // PIB-082: the gallery says the camera holds its own gallery instead of "No clips".
        #expect(browse.heldBySource == true)
        await browse.close()
        await browse.close()
        #expect(peer.returns == 1 && peer.enables == 1 && peer.exits == 1)
        #expect(peer.completions == [.restored])
        #expect(peer.admissions == [true, false])
    }

    @Test func failedEntryStillListsNewestPageWithActualRecords() async throws {
        let peer = MediaPeer()
        peer.enterSuccess = false
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        #expect(peer.entries == 3)
        #expect(peer.wireHeld == [true, false])
        #expect(clock.delays.filter { $0 == .milliseconds(120) }.count == 3)
        #expect(peer.writes.count == 3)
        #expect(peer.ingress.capture() == nil)
        #expect(page.reset && page.complete && page.upserts.count == 34)
        let asset = try #require(page.upserts.first)
        let capture = try #require(service.mediaCatalogRecord(asset.id, binding: browse.binding))
        #expect(capture.file.filename == "DJI_20260814125250_0034_D.MP4")
        #expect(capture.file.fps == 25 && capture.file.resolution == "3840x2160")
        #expect(asset.frameRate == 25 && asset.pixelSize == .init(width: 3840, height: 2160))
        #expect(asset.colorLabel == nil && page.volumes == nil)
        #expect(asset.deletable == capture.file.isDeletable)
        #expect(try await cursor.next() == nil)
        service.retire()
    }

    @Test func successfulEntryRetriesEmptySDOnceWithDonorWireOrder() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        #expect(peer.entries == 1 && page.upserts.count == 34)
        #expect(peer.writes.map { $0.payload[1] } == [0, 4, 0, 0, 4])
        #expect(peer.writes.map { $0.payload[4] } == [1, 1, 2, 1, 1])
        #expect(clock.now <= 12)
        service.retire()
    }

    @Test func missingResponsesNeverBecomeKnownEmptyCatalog() async throws {
        let peer = MediaPeer()
        peer.inject = false
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        do {
            _ = try await cursor.next()
            Issue.record("No response must remain unavailable")
        } catch { #expect(error as? MediaServiceError == .unavailable) }
        #expect(clock.now <= 12 && peer.writes.count == 5)
        service.retire()
    }

    @Test func actualEmptyResponsesPublishKnownEmptyCatalog() async throws {
        let peer = MediaPeer()
        peer.manifest = false
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        let page = try #require(try await cursor.next())
        #expect(page.reset && page.complete && page.upserts.isEmpty && page.volumes == nil)
        #expect(peer.ingress.capture() == nil)
        service.retire()
    }

    @Test func replacedCursorRefusesOldIngressAndDoesNotBlockSuccessor() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let first = try await browse.catalog()
        clock.pauseNext = true
        let old = Task { try await first.next() }
        for _ in 0..<1000 where clock.paused == nil { await Task.yield() }
        #expect(clock.paused != nil)
        peer.retiredTicket = peer.ticket
        let second = try await browse.catalog()
        let page = try #require(try await second.next())
        #expect(page.upserts.count == 34)
        clock.release()
        do {
            _ = try await old.value
            Issue.record("Old cursor must be retired")
        } catch { #expect(error is CancellationError || error as? MediaServiceError == .retired) }
        service.retire()
    }

    @Test func lateRecordAndCloseCannotAffectSuccessorBrowse() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let old = try await service.openBrowse()
        let cursor = try await old.catalog()
        let page = try #require(try await cursor.next())
        let asset = try #require(page.upserts.first)
        let successor = try await service.openBrowse()
        #expect(service.mediaCatalogRecord(asset.id, binding: old.binding) == nil)
        await old.close()
        #expect(peer.returns == 0 && peer.enables == 0)
        #expect(successor.binding != old.binding)
        service.retire()
    }

    @Test func concurrentPullRefusesWithoutResettingAdmittedQuery() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        clock.pauseNext = true
        let pending = Task { try await cursor.next() }
        for _ in 0..<1000 where clock.paused == nil { await Task.yield() }
        #expect(clock.paused != nil)
        let ticket = peer.ingress.capture()
        do {
            _ = try await cursor.next()
            Issue.record("Concurrent pull must refuse")
        } catch { #expect(error as? MediaServiceError == .unavailable) }
        #expect(peer.ingress.capture() == ticket && peer.writes.count == 1)
        clock.release()
        let page = try #require(try await pending.value)
        #expect(page.upserts.count == 34)
        service.retire()
    }

    @Test func catalogEpochRetiresSuspendedPageButKeepsSameSessionReturn() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        clock.pauseNext = true
        let pending = Task { try await cursor.next() }
        for _ in 0..<1000 where clock.paused == nil { await Task.yield() }
        #expect(clock.paused != nil)
        peer.mediaFacts = .init(
            identity: .init(session: peer.session, epoch: .init(2), cameraID: "SIMULATED-camera"),
            canQuery: false, bodyGalleryOpen: false, inPlayback: false)
        clock.release()
        do {
            _ = try await pending.value
            Issue.record("Old source epoch must not publish")
        } catch { #expect(error as? MediaServiceError == .retired) }
        #expect(peer.writes.count == 1 && peer.ingress.capture() == nil)
        await browse.close()
        #expect(peer.returns == 1 && peer.completions == [.restored])
    }

    @Test func nativeEndpointReplacementRetiresCatalogButKeepsCurrentCloseAuthority() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        let cursor = try await browse.catalog()
        clock.pauseNext = true
        let pending = Task { try await cursor.next() }
        for _ in 0..<1000 where clock.paused == nil { await Task.yield() }
        #expect(clock.paused != nil && peer.ingress.capture() != nil)
        let successorSlot = DjiAppleMediaIngressSlot()
        service.attachIngress(successorSlot)
        #expect(peer.ingress.capture() == nil && successorSlot.capture() == nil)
        clock.release()
        do {
            _ = try await pending.value
            Issue.record("Old endpoint cannot publish a catalog page")
        } catch { #expect(error is CancellationError || error as? MediaServiceError == .retired) }
        await browse.close()
        #expect(peer.returns == 1 && peer.completions == [.restored])
    }

    @Test func sameSessionReturnSurvivesCatalogEpochAndNilDriverGap() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        peer.mediaFacts = .init(
            identity: .init(session: peer.session, epoch: .init(2), cameraID: "SIMULATED-camera"),
            canQuery: false, bodyGalleryOpen: false, inPlayback: false)
        await browse.close()
        #expect(peer.returns == 1 && peer.completions == [.restored])
        #expect(peer.enables == 1 && peer.writes.isEmpty)
    }

    @Test func connectionRetirementSendsNoReturnCommands() async throws {
        let peer = MediaPeer()
        let clock = MediaClock()
        let service = owner(peer, clock)
        let browse = try await service.openBrowse()
        service.retire()
        await browse.close()
        #expect(peer.returns == 0 && peer.exits == 0 && peer.enables == 0 && peer.writes.isEmpty)
    }
    @Test func legacyAssetFactoryUsesExactlyTheProducedContentIdentity() async throws {
        let peer = MediaPeer(), clock = MediaClock(), service = owner(peer, clock)
        let browse = try await service.openBrowse(), cursor = try await browse.catalog()
        let page = try #require(try await cursor.next()), asset = try #require(page.upserts.first)
        let captured = try #require(service.mediaCatalogRecord(asset.id, binding: browse.binding))
        #expect(DjiAppleMediaAssets.asset(for: captured.file) == asset)
        var recycled = captured.file; recycled.sizeBytes += 1
        #expect(MediaListCommand.pageKey(recycled) == MediaListCommand.pageKey(captured.file))
        #expect(DjiAppleMediaAssets.asset(for: recycled).id != asset.id)
        service.retire()
    }
    @Test func assetIsDeletableExactlyWhenItsFileHasAnOwnHandle() {
        let file = MediaFile(path: "DCIM/DJI_001/DJI_20260912120000_0001_D.MP4", thumbPath: "", handle: 7)
        #expect(DjiAppleMediaAssets.asset(for: file).deletable == true)
        var shared = file; shared.handleShared = true
        #expect(DjiAppleMediaAssets.asset(for: shared).deletable == false)
        var unknown = file; unknown.handle = 0
        #expect(DjiAppleMediaAssets.asset(for: unknown).deletable == false)
    }
    @Test func newestPageRemovesOnlyOldContentProvenAtTheSamePageKey() async throws {
        let peer = MediaPeer(), clock = MediaClock(), service = owner(peer, clock)
        let browse = try await service.openBrowse(), cursor = try await browse.catalog()
        let first = try #require(try await cursor.next()), old = try #require(first.upserts.first)
        let captured = try #require(service.mediaCatalogRecord(old.id, binding: browse.binding))
        let before = captured.file.sizeBytes, after = before + 1024
        #expect(before > 0 && after <= UInt32.max)
        peer.transformManifest = { data in
            var oldBytes = UInt32(before).littleEndian, newBytes = UInt32(after).littleEndian
            let oldSize = withUnsafeBytes(of: &oldBytes) { Data($0) }
            let newSize = withUnsafeBytes(of: &newBytes) { Data($0) }
            let range = try #require(data.range(of: oldSize))
            var replaced = data; replaced.replaceSubrange(range, with: newSize)
            #expect(MediaManifest.decode(replaced).first?.sizeBytes == after)
            return replaced
        }
        let newest = try service.newestCatalog(binding: browse.binding)
        let delta = try #require(try await newest.next()), replacement = try #require(delta.upserts.first)
        #expect(!delta.reset && delta.removed == [old.id] && replacement.id != old.id)
        let fresh = try #require(service.mediaCatalogRecord(replacement.id, binding: browse.binding))
        #expect(fresh.file.sizeBytes == after && fresh.file.id == captured.file.id)
        #expect(service.mediaCatalogRecord(old.id, binding: browse.binding) == nil)
        #expect(first.upserts.dropFirst().allSatisfy { service.mediaCatalogRecord($0.id, binding: browse.binding) != nil })
        #expect(try await newest.next() == nil)
        service.retire()
    }

}
