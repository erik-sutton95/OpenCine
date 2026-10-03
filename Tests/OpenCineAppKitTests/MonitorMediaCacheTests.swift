import Foundation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor @Suite struct MonitorMediaCacheTests {
    private func directory() -> (URL, MonitorMediaCacheDirectory) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("opencine-cache-" + UUID().uuidString)
        return (parent, MonitorMediaCacheDirectory(root: parent.appendingPathComponent("camera")))
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
