import CoreBluetooth
import OpenCineCore
import Testing
@testable import Insta360Apple

/// Device cell 7d (DEF-INSTA-LUNA-OFF-RECOVERY): Luna fully off, then back on.
@Suite struct LunaBluetoothRecoveryTests {
    /// A connect still pending for an absent camera is cancelled without any callback. Waiting
    /// for one left the camera marked "still closing" for the rest of the launch, so every
    /// later Try again failed until the app was relaunched.
    @Test func cancellingAPendingConnectAwaitsNoCallback() {
        #expect(!LunaBluetooth.awaitsCloseCallback(.connecting))
        #expect(!LunaBluetooth.awaitsCloseCallback(.disconnected))
        #expect(LunaBluetooth.awaitsCloseCallback(.connected))
        #expect(LunaBluetooth.awaitsCloseCallback(.disconnecting))
    }

    /// A camera that is off or out of range is named as missing, not as a Bluetooth conflict.
    @Test func timeoutForACameraNotAdvertisingSaysItIsMissing() {
        let missing = LunaBluetooth.connectTimeoutFailure(advertisedRecently: false)
        #expect(missing.reason == .notFound)
        #expect(missing.message.contains("turned on"))
        #expect(!missing.message.contains("other devices"))
        let held = LunaBluetooth.connectTimeoutFailure(advertisedRecently: true)
        #expect(held.reason == .timedOut)
        #expect(held.message.contains("other devices"))
    }
}
