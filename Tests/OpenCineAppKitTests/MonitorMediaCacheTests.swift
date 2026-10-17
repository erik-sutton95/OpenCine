import Foundation
@testable import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor @Suite struct MonitorMediaCacheTests {
    @Test(.serialized, arguments: CacheWriterRetirement.allCases)
    func heldRealWriteDoesNotBlockAdmissionOrSuccessor(_ retirement: CacheWriterRetirement) async throws {
        let (parent, directory) = directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let metadata = Data("{\"unknown\":19}".utf8)
        try directory.write(metadata, at: "index.json")
        try directory.write(Data([42]), at: "camera-object.part")
        let generation = directory.generation
        let control = ControlledCacheWrite()
        let old = try directory.beginWrite(at: "files/take.mov", writeOperation: { handle, bytes in
            try control.write(handle, bytes)
        })
        defer { control.release(); old.abort() }
        let operation = Task.detached { try await old.write(Data([1, 2])) }
        #expect(await control.waitUntilEntered())
        control.startAdmissionDeadline()
        // RED blocks here until the independent controller releases old I/O. GREEN must
        // finish admission AND publish the exact successor while old I/O is still held.
        #expect(directory.generation == generation)
        switch retirement {
        case .retire: directory.retireWrites()
        case .replace: break
        case .abort: old.abort()
        case .clear: try await directory.clear(preserving: ["index.json", "camera-object.part", "files"])
        }
        if retirement == .retire || retirement == .clear { #expect(directory.generation != generation) }
        let successor = try directory.beginWrite(at: "files/take.mov")
        defer { successor.abort() }
        try await successor.write(Data([7, 8, 9]))
        let committed = try successor.commit(.init(byteCount: 3))
        #expect(control.admissionFinishedBeforeRelease())
        await #expect(throws: MonitorMediaCacheError.retired) { try await operation.value }
        #expect(throws: MonitorMediaCacheError.retired) { try old.commit(.init(byteCount: 2)) }
        old.abort()
        #expect(try Data(contentsOf: committed) == Data([7, 8, 9]))
        #expect(try directory.read("index.json") == metadata)
        #expect(try directory.read("camera-object.part") == Data([42]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.root.appendingPathComponent("files").path) == ["take.mov"])
        #expect(!control.hitFailureDeadline)
    }

    @Test func retirementScanningChecksOwnershipBeforeMetadata() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let unrelated = ["other", ".clearing-camera-invalid", ".clearing-camera-extra-" + UUID().uuidString]
        let manager = RetirementMetadataFileManager(unrelated: Set(unrelated))
        let directory = MonitorMediaCacheDirectory(root: parent.appendingPathComponent("camera"), fileManager: manager)
        let prepared = parent.appendingPathComponent(".clearing-camera-" + UUID().uuidString)
        let unprepared = parent.appendingPathComponent(".retiring-camera-" + UUID().uuidString)
        for (root, count) in [(directory.root, 2), (prepared, 3), (unprepared, 5)] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(repeating: 1, count: count).write(to: root.appendingPathComponent("take.mov"))
        }
        for name in unrelated {
            try FileManager.default.createDirectory(at: parent.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let linked = parent.appendingPathComponent(".clearing-camera-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: parent.appendingPathComponent("other"))
        #expect(await directory.totalByteCount() == 10)
        #expect(manager.unrelatedLookups.isEmpty)
        try await directory.clear(preserving: [])
        #expect(manager.unrelatedLookups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: prepared.path))
        #expect(try Data(contentsOf: unprepared.appendingPathComponent("take.mov")) == Data(repeating: 1, count: 5))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linked.path) == parent.appendingPathComponent("other").path)
        for name in unrelated { #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path)) }
    }

    @Test func retiringWritesPreservesResumableFilesAndFencesOldFinally() async throws {
        let (parent, directory) = directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: directory.root, withIntermediateDirectories: true)
        let partial = directory.root.appendingPathComponent("camera-object.part")
        try Data([8, 9]).write(to: partial)
        let old = try directory.beginWrite(at: "take.mov")
        try await old.write(Data([1]))
        let generation = directory.generation
        directory.retireWrites()
        #expect(generation != directory.generation)
        let current = try directory.beginWrite(at: "take.mov")
        try await current.write(Data([2, 3]))
        let committed = try current.commit(.init(byteCount: 2))
        #expect(throws: MonitorMediaCacheError.retired) { try old.commit(.init(byteCount: 1)) }
        old.abort()
        #expect(try Data(contentsOf: committed) == Data([2, 3]))
        #expect(try Data(contentsOf: partial) == Data([8, 9]))
    }
    private func directory() -> (URL, MonitorMediaCacheDirectory) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-cache-" + UUID().uuidString)
        return (parent, MonitorMediaCacheDirectory(root: parent.appendingPathComponent("camera")))
    }
    private struct RetirementFixture {
        let parent: URL, ownPrepared: URL, ownUnprepared: URL, siblingPrepared: URL, siblingUnprepared: URL
        let own: MonitorMediaCacheDirectory, sibling: MonitorMediaCacheDirectory
    }
    private func retirementFixture() throws -> RetirementFixture {
        let (parent, own) = directory()
        let sibling = MonitorMediaCacheDirectory(root: parent.appendingPathComponent("camera-extra"))
        let ownPrepared = parent.appendingPathComponent(".clearing-camera-" + UUID().uuidString)
        let ownUnprepared = parent.appendingPathComponent(".retiring-camera-" + UUID().uuidString)
        let siblingPrepared = parent.appendingPathComponent(".clearing-camera-extra-" + UUID().uuidString)
        let siblingUnprepared = parent.appendingPathComponent(".retiring-camera-extra-" + UUID().uuidString)
        for (root, count) in [(own.root, 2), (ownPrepared, 7), (ownUnprepared, 5),
            (sibling.root, 17), (siblingPrepared, 11), (siblingUnprepared, 13)] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(repeating: UInt8(count), count: count).write(to: root.appendingPathComponent("take.mov"))
        }
        return .init(parent: parent, ownPrepared: ownPrepared, ownUnprepared: ownUnprepared,
            siblingPrepared: siblingPrepared, siblingUnprepared: siblingUnprepared, own: own, sibling: sibling)
    }
    @Test func prefixOverlappingRootsDoNotShareRetiredByteCounts() async throws {
        let fixture = try retirementFixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        #expect(await fixture.own.totalByteCount() == 14)
        #expect(await fixture.sibling.totalByteCount() == 41)
    }
    @Test func clearPreservesPrefixOverlappingRetiredRoots() async throws {
        let fixture = try retirementFixture(); defer { try? FileManager.default.removeItem(at: fixture.parent) }
        try await fixture.own.clear(preserving: [])
        #expect(!FileManager.default.fileExists(atPath: fixture.ownPrepared.path))
        #expect(try Data(contentsOf: fixture.ownUnprepared.appendingPathComponent("take.mov")) == Data(repeating: 5, count: 5))
        #expect(try Data(contentsOf: fixture.sibling.root.appendingPathComponent("take.mov")) == Data(repeating: 17, count: 17))
        #expect((try? Data(contentsOf: fixture.siblingPrepared.appendingPathComponent("take.mov"))) == Data(repeating: 11, count: 11))
        #expect(try Data(contentsOf: fixture.siblingUnprepared.appendingPathComponent("take.mov")) == Data(repeating: 13, count: 13))
        #expect(await fixture.own.totalByteCount() == 5)
        #expect(await fixture.sibling.totalByteCount() == 41)
    }
    @Test func unrecognizedRetirementNamesRemainOutsideOwnedCache() async throws {
        let (parent, directory) = directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let names = [".clearing-camera-retry", ".retiring-camera-1-1-1-1-1",
            ".clearing-camera-" + UUID().uuidString + "-extra"]
        for name in names {
            let root = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: root.appendingPathComponent("take.mov"))
        }
        #expect(await directory.totalByteCount() == 0)
        try await directory.clear(preserving: [])
        for name in names {
            #expect(try Data(contentsOf: parent.appendingPathComponent(name).appendingPathComponent("take.mov")) == Data([1, 2, 3]))
        }
    }
    @Test func clearRetiresOldWriterBeforeNewRootCommit() async throws {
        let (parent, directory) = directory(); defer { try? FileManager.default.removeItem(at: parent) }
        try directory.write(Data("{\"unknown\":19}".utf8), at: "index.json")
        let old = try directory.beginWrite(at: "files/take.mov")
        try await old.write(Data([1]))
        try await directory.clear(preserving: ["index.json"])
        let current = try directory.beginWrite(at: "files/take.mov")
        try await current.write(Data([2, 3]))
        let committed = try current.commit(.init(byteCount: 2))
        await #expect(throws: MonitorMediaCacheError.retired) { try await old.write(Data([4])) }
        #expect(throws: MonitorMediaCacheError.retired) { try old.commit(.init(byteCount: 1)) }
        old.abort()
        #expect(try Data(contentsOf: committed) == Data([2, 3]))
        #expect(try directory.read("index.json") == Data("{\"unknown\":19}".utf8))
    }
    @Test func replacementAtSameDestinationRejectsOldCommitAndFinally() async throws {
        let (parent, directory) = directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let old = try directory.beginWrite(at: "files/take.mov"); try await old.write(Data([1]))
        let current = try directory.beginWrite(at: "files/take.mov"); try await current.write(Data([2]))
        let url = try current.commit(.init(byteCount: 1))
        #expect(throws: MonitorMediaCacheError.retired) { try old.commit(.init(byteCount: 1)) }
        old.abort()
        #expect(try Data(contentsOf: url) == Data([2]))
    }
    @Test func originalEligibilityPreservesNinetyPercentVersusExactSize() {
        let apple = MonitorMediaOriginalEligibility.minimumFraction(numerator: 9, denominator: 10)
        #expect(!apple.accepts(bytes: 89, expected: 100) && apple.accepts(bytes: 90, expected: 100))
        #expect(apple.accepts(bytes: 91, expected: 100))
        #expect(!MonitorMediaOriginalEligibility.exactSize.accepts(bytes: 99, expected: 100))
        #expect(MonitorMediaOriginalEligibility.exactSize.accepts(bytes: 100, expected: 100))
        #expect(!MonitorMediaOriginalEligibility.exactSize.accepts(bytes: 101, expected: 100))
        #expect(apple.accepts(bytes: 1, expected: nil) && !apple.accepts(bytes: 0, expected: nil))
        #expect(apple.accepts(bytes: UInt64.max, expected: UInt64.max))
    }
    @Test func invalidReceiptCannotPublishStagedBytes() async throws {
        let (parent, directory) = directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let writer = try directory.beginWrite(at: "files/take.mov"); try await writer.write(Data([1, 2]))
        #expect(throws: MonitorMediaCacheError.invalidReceipt) { try writer.commit(.init(byteCount: 4)) }
        writer.abort()
        #expect(directory.existing("files/take.mov") == nil)
        #expect(await directory.totalByteCount() == 0)
    }
    @Test func explicitAddressCannotEscapeTheOwnedRoot() throws {
        let (parent, directory) = directory(); defer { try? FileManager.default.removeItem(at: parent) }
        for address in ["../other", "/other", "files/../other", "files\\other", ""] {
            #expect(throws: MonitorMediaCacheError.invalidAddress) { try directory.beginWrite(at: address) }
        }
    }
}

// The real writer is paused just before its real FileHandle operation. No sleep or
// timing-based success assertion: admission is recorded before any release. The failure
// deadline starts at admission, after the old write is held, and reports RED instead
// of deadlocking MainActor if admission waits on that write. A separate equal bound
// covers only the wait for the old write to enter, so a writer that never reaches IO
// fails instead of suspending MainActor forever.
enum CacheWriterRetirement: CaseIterable, Sendable { case retire, replace, abort, clear }
private final class RetirementMetadataFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let unrelated: Set<String>
    private var lookups: [String] = []
    init(unrelated: Set<String>) { self.unrelated = unrelated; super.init() }
    var unrelatedLookups: [String] {
        lock.lock(); defer { lock.unlock() }; return lookups
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if unrelated.contains(URL(fileURLWithPath: path).lastPathComponent) {
            lock.lock(); lookups.append(path); lock.unlock()
        }
        return try super.attributesOfItem(atPath: path)
    }
}
private final class ControlledCacheWrite: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var admissionFinished = false
    private var deadlineHit = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    init() {
        Thread.detachNewThread { [self] in
            let deadline = Date().addingTimeInterval(5)
            condition.lock()
            while !entered && !released && condition.wait(until: deadline) {}
            var pending: [CheckedContinuation<Bool, Never>] = []
            if !entered && !released {
                deadlineHit = true; released = true
                pending = waiters; waiters.removeAll(); condition.broadcast()
            }
            condition.unlock()
            for waiter in pending { waiter.resume(returning: false) }
        }
    }
    func startAdmissionDeadline() {
        Thread.detachNewThread { [self] in
            let deadline = Date().addingTimeInterval(5)
            condition.lock()
            while !admissionFinished && !released {
                if !condition.wait(until: deadline) {
                    deadlineHit = true
                    break
                }
            }
            released = true
            let pending = waiters; waiters.removeAll()
            let didEnter = entered
            condition.broadcast(); condition.unlock()
            for waiter in pending { waiter.resume(returning: didEnter) }
        }
    }
    func write(_ handle: FileHandle, _ bytes: Data) throws {
        condition.lock(); entered = true; condition.broadcast()
        let pending = waiters; waiters.removeAll(); condition.unlock()
        for waiter in pending { waiter.resume(returning: true) }
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
        try handle.write(contentsOf: bytes)
    }
    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { waiter in
            condition.lock()
            if entered || released {
                let didEnter = entered
                condition.unlock(); waiter.resume(returning: didEnter)
            } else { waiters.append(waiter); condition.unlock() }
        }
    }
    func admissionFinishedBeforeRelease() -> Bool {
        condition.lock()
        let ordered = entered && !released
        admissionFinished = true
        condition.broadcast(); condition.unlock()
        return ordered
    }
    var hitFailureDeadline: Bool {
        condition.lock(); defer { condition.unlock() }; return deadlineHit
    }
    func release() {
        condition.lock(); released = true
        let pending = waiters; waiters.removeAll()
        let didEnter = entered
        condition.broadcast(); condition.unlock()
        for waiter in pending { waiter.resume(returning: didEnter) }
    }
}
