#if os(iOS)
    import MonitorUI
    import SwiftUI
    import UIKit
    import XCTest

    final class MonitorThemeFontTests: XCTestCase {
        func testSharedPackageFacesRegister() {
            _ = MonitorTheme.font(16)
            for name in ["Sora-Regular", "Sora-Medium", "Sora-SemiBold", "Sora-Bold"] {
                XCTAssertNotNil(
                    UIFont(name: name, size: 16),
                    "MonitorUI should register shared face \(name)")
            }
        }
    }
#endif
