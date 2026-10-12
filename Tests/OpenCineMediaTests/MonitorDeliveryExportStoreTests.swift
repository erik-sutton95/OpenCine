import Foundation
import OpenCineMedia
import Testing

/// A2-58: delivery files live in one store, for exactly as long as their run or share sheet.
@Suite struct MonitorDeliveryExportStoreTests {
    @Test func exportsLiveForTheirRunAndShareCopiesForTheirSheet() throws {
        try withStore { store in
            let first = try store.outputURL(filename: "C0001.MOV")
            let second = try store.outputURL(filename: " C0001.MOV ")
            #expect(first != second && second.lastPathComponent == "C0001.MOV")
            try Data([1, 2, 3]).write(to: first)
            try Data([4, 5]).write(to: second)
            let shared = try store.stage([first])
            let lease = try #require(shared.stagingCleanupURL)
            store.release(first)
            store.release(second)
            #expect(!FileManager.default.fileExists(atPath: first.path))
            #expect(!FileManager.default.fileExists(atPath: second.deletingLastPathComponent().path))
            #expect(try Data(contentsOf: shared.urls[0]) == Data([1, 2, 3]))
            #expect(store.byteCount() > 0)
            store.release(lease)
            #expect(!FileManager.default.fileExists(atPath: lease.path))
            #expect(store.byteCount() == 0)
        }
    }

    @Test func stillAndMovieOriginalsBothReachTheShareAndBorrowedFilesStay() throws {
        try withStore { store in
            let cache = store.root.deletingLastPathComponent().appendingPathComponent("cache")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let still = cache.appendingPathComponent("SIMULATED_0001.JPG")
            let movie = cache.appendingPathComponent("SIMULATED_0002.MOV")
            let sidecar = cache.appendingPathComponent("SIMULATED_0002.json")
            for url in [still, movie, sidecar] { try Data([1, 2, 3]).write(to: url) }
            let shared = try store.stage([still, movie, sidecar])
            #expect(shared.urls.map(\.lastPathComponent) == ["SIMULATED_0001.JPG", "SIMULATED_0002.MOV"])
            store.release(still)
            store.release(shared.stagingCleanupURL)
            #expect(FileManager.default.fileExists(atPath: still.path))
            #expect(FileManager.default.fileExists(atPath: movie.path))
        }
    }

    @Test func pruneRemovesOnlyFilesNoRunOrSheetHolds() throws {
        try withStore { store in
            let held = try store.outputURL(filename: "HELD.MOV")
            try Data([1]).write(to: held)
            let crash = store.exportsDirectory.appendingPathComponent("left-by-a-crash")
            try FileManager.default.createDirectory(at: crash, withIntermediateDirectories: true)
            try Data([2]).write(to: crash.appendingPathComponent("OLD.MOV"))
            store.prune()
            #expect(FileManager.default.fileExists(atPath: held.path))
            #expect(!FileManager.default.fileExists(atPath: crash.path))
            let relaunched = MonitorDeliveryExportStore(root: store.root)
            relaunched.prune()
            #expect(!FileManager.default.fileExists(atPath: held.path))
        }
    }

    @Test func emptyOrPathFilenamesAreRefused() throws {
        try withStore { store in
            for name in ["", "  ", "a/b.mov", ".."] {
                #expect(throws: MonitorDeliveryExportStore.StoreError.self) {
                    try store.outputURL(filename: name)
                }
            }
        }
    }

    private func withStore(_ body: (MonitorDeliveryExportStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "opencine-exports-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(MonitorDeliveryExportStore(root: root.appendingPathComponent("store")))
    }
}
