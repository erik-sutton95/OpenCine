#if os(iOS)
import ObjectiveC
import OpenCineAppKitApple
import Photos
import XCTest
import os

@MainActor
final class MonitorDeliveryPhotosSaverTests: XCTestCase {
    /// OPENPOCKETCINE-IOS-3P: PhotoKit runs the change block on its own queue, so a block that
    /// inherited the saver's main-actor isolation trapped on every Save to Photos.
    func testChangeBlockRunsOnThePhotoKitQueue() async throws {
        let offMainBlocks = OSAllocatedUnfairLock(initialState: 0)
        let restore = PhotoKitThreading.install(countingOffMainBlocks: offMainBlocks)
        defer { restore() }
        // A sidecar is neither a movie nor a still (stills are saved too), so there is nothing to
        // create: the block runs and the transaction commits empty.
        let saved = try await MonitorDeliveryPhotosSaver.save(at: [URL(fileURLWithPath: "/tmp/clip.xml")])
        XCTAssertEqual(saved, 0)
        XCTAssertEqual(offMainBlocks.withLock { $0 }, 1)
    }
}

/// PhotoKit's threading without a photo library (the test runner has no Photos access): the same
/// Objective-C entry points the saver calls answer authorization and run the change block on a
/// private queue. Returns the restore action.
private enum PhotoKitThreading {
    typealias Perform = @convention(block) (
        AnyObject, @escaping @convention(block) () -> Void, (@convention(block) (Bool, NSError?) -> Void)?
    ) -> Void
    typealias Authorize = @convention(block) (
        AnyObject, PHAccessLevel, @escaping @convention(block) (PHAuthorizationStatus) -> Void
    ) -> Void

    static func install(countingOffMainBlocks offMain: OSAllocatedUnfairLock<Int>) -> () -> Void {
        let changes = DispatchQueue(label: "test.photokit.changes")
        let perform: Perform = { _, block, completion in
            nonisolated(unsafe) let block = block
            nonisolated(unsafe) let completion = completion
            changes.async {
                block()
                if !Thread.isMainThread { offMain.withLock { $0 += 1 } }
                completion?(true, nil)
            }
        }
        let authorize: Authorize = { _, _, handler in handler(.authorized) }
        guard
            let performMethod = class_getInstanceMethod(
                PHPhotoLibrary.self, NSSelectorFromString("performChanges:completionHandler:")),
            let authorizeMethod = class_getClassMethod(
                PHPhotoLibrary.self, NSSelectorFromString("requestAuthorizationForAccessLevel:handler:"))
        else { fatalError("PhotoKit entry points moved") }
        let originalPerform = method_setImplementation(performMethod, imp_implementationWithBlock(perform))
        let originalAuthorize = method_setImplementation(authorizeMethod, imp_implementationWithBlock(authorize))
        return {
            method_setImplementation(performMethod, originalPerform)
            method_setImplementation(authorizeMethod, originalAuthorize)
        }
    }
}
#endif
