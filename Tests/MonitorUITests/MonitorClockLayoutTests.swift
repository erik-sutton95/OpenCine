#if os(iOS)
import MonitorUI
import SwiftUI
import UIKit
import XCTest

final class MonitorClockLayoutTests: XCTestCase {
    @MainActor func testFrameDigitsKeepTheSameNativeClockSize() {
        for size in [CGFloat(15), 23, 25] {
            let host = UIHostingController(rootView: MonitorClock("01:23:45:00", fontSize: size))
            let proposal = CGSize(width: 500, height: 100)
            let original = host.sizeThatFits(in: proposal)
            XCTAssertGreaterThan(original.width, 0)
            for frame in 0...59 {
                host.rootView = MonitorClock(String(format: "01:23:45:%02d", frame), fontSize: size)
                host.view.invalidateIntrinsicContentSize()
                host.view.layoutIfNeeded()
                let measured = host.sizeThatFits(in: proposal)
                XCTAssertEqual(measured.width, original.width, accuracy: 0.01, "Frame \(frame)")
                XCTAssertEqual(measured.height, original.height, accuracy: 0.01, "Frame \(frame)")
            }
        }
    }
}
#endif
