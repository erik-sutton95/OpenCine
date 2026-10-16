#if os(iOS)
    @testable import MonitorUI
    import SwiftUI
    import UIKit
    import XCTest

    /// A2-84: a settings tab reopens exactly where it came to rest, not on the last throttled
    /// sample of the drag (the UI tests saw 180 against 176 before the trailing commit).
    @MainActor
    final class MonitorSettingsScrollMemoryTests: XCTestCase {
        func testRestoresTheSavedOffsetExactly() {
            let page = Self.page()
            // A saved offset is one the page itself reported, so it is on the display's pixel
            // grid (UIScrollView snaps any other value to it): 517 is on every grid.
            let saved = SavedOffset(517)
            MonitorSettingsScrollMemory().attach(page, savedOffset: saved.binding)
            XCTAssertEqual(page.contentOffset.y, 517)
        }

        func testASmallFinalMoveIsCommittedWhenThePageSettles() {
            let page = Self.page()
            let saved = SavedOffset(176)
            let memory = MonitorSettingsScrollMemory()
            memory.attach(page, savedOffset: saved.binding)
            // A deceleration tail: each step is below the 10 point throttle.
            for y in [178.0, 179.5, 180.0] { page.contentOffset.y = y }
            memory.settle()
            XCTAssertEqual(saved.value, 180)
        }

        func testTheSettleCommitFollowsTheLastMoveWithoutAnExplicitCall() async {
            let page = Self.page()
            let rested = expectation(description: "the resting offset is committed")
            let saved = SavedOffset(0) { if $0 == 304 { rested.fulfill() } }
            let memory = MonitorSettingsScrollMemory(settleDelay: .milliseconds(20))
            memory.attach(page, savedOffset: saved.binding)
            page.contentOffset.y = 300
            page.contentOffset.y = 304
            await fulfillment(of: [rested], timeout: 5)
            XCTAssertEqual(saved.value, 304)
        }

        func testLeavingThePageCommitsWhereItWasLeft() async {
            let page = Self.page()
            let left = expectation(description: "the offset at close is committed")
            let saved = SavedOffset(0) { if $0 == 333 { left.fulfill() } }
            let memory = MonitorSettingsScrollMemory(settleDelay: .seconds(60))
            memory.attach(page, savedOffset: saved.binding)
            page.contentOffset.y = 333
            memory.detach()
            await fulfillment(of: [left], timeout: 5)
        }

        func testARubberBandPositionIsNeverSaved() {
            let page = Self.page()
            let saved = SavedOffset(120)
            let memory = MonitorSettingsScrollMemory()
            memory.attach(page, savedOffset: saved.binding)
            page.contentOffset.y = -30
            memory.settle()
            page.contentOffset.y = 2_000
            memory.settle()
            XCTAssertEqual(saved.value, 120)
        }

        private static func page() -> UIScrollView {
            let page = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
            page.contentSize = CGSize(width: 390, height: 2_400)
            return page
        }
    }

    @MainActor
    private final class SavedOffset {
        private(set) var value: CGFloat
        private let didSet: (CGFloat) -> Void

        init(_ value: CGFloat, didSet: @escaping (CGFloat) -> Void = { _ in }) {
            self.value = value
            self.didSet = didSet
        }

        var binding: Binding<CGFloat> {
            Binding(get: { self.value }, set: { self.value = $0; self.didSet($0) })
        }
    }
#endif
