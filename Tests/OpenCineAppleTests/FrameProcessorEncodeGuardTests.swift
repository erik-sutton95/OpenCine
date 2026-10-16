#if canImport(Metal) && canImport(VideoToolbox)
    import Foundation
    import Metal
    import OpenCineAppleObjC
    import XCTest

    /// OPENPOCKETCINE-IOS-3M and -3W: VideoToolbox raised NSInvalidArgumentException from inside
    /// `processWithCommandBuffer:parameters:` and, because Swift cannot catch an NSException,
    /// the app died on the draw thread. The guard turns that raise into a refused frame.
    /// SIMULATED processors: the real model exists only on device hardware.
    final class FrameProcessorEncodeGuardTests: XCTestCase {
        /// Stands in for `VTFrameProcessor`, raising the way the field crash did.
        @objc private final class RaisingProcessor: NSObject {
            @objc(processWithCommandBuffer:parameters:)
            func process(_ commandBuffer: MTLCommandBuffer, parameters: AnyObject) {
                NSException(
                    name: .invalidArgumentException,
                    reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                    userInfo: nil
                ).raise()
            }
        }

        @objc private final class CountingProcessor: NSObject {
            var calls = 0
            @objc(processWithCommandBuffer:parameters:)
            func process(_ commandBuffer: MTLCommandBuffer, parameters: AnyObject) { calls += 1 }
        }

        private func commandBuffer() throws -> MTLCommandBuffer {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device on this host")
            return try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        }

        func testRaisedNilInsertBecomesARefusalInsteadOfACrash() throws {
            let refusal = frameProcessorEncode(
                RaisingProcessor(), commandBuffer: try commandBuffer(), parameters: NSObject())
            XCTAssertEqual(
                refusal,
                "NSInvalidArgumentException: *** -[__NSArrayM insertObject:atIndex:]: object cannot be nil")
        }

        func testAProcessorThatReturnsIsCalledOnceAndReportsNothing() throws {
            let processor = CountingProcessor()
            XCTAssertNil(frameProcessorEncode(processor, commandBuffer: try commandBuffer(), parameters: NSObject()))
            XCTAssertEqual(processor.calls, 1)
        }
    }
#endif
