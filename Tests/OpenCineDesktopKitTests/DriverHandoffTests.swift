import Foundation
import Testing

@testable import OpenCineDesktopKit

/// The dock reaches a driver that appears after it started, without a relaunch.
@Suite struct DriverHandoffTests {
    /// A dock whose own device list stays stale, and a driver that appears later.
    private final class Mac {
        var driverRunning = false
        var freshProcessesStarted = 0
        var received: [String] = []

        /// The running dock: it never sees the driver that appeared after it first looked.
        func thisProcess() -> Bool { false }

        /// A process started now sees whatever is running now.
        func freshProcess(_ payload: String) -> Bool {
            freshProcessesStarted += 1
            guard driverRunning else { return false }
            received.append(payload)
            return true
        }
    }

    @Test func aDriverThatAppearsAfterTheDockStartedGetsTheTableAndSelection() {
        let mac = Mac()
        func deliver(_ payload: String, enabled: Bool) -> DriverHandoff.Route? {
            DriverHandoff.deliver(
                driverEnabled: enabled, thisProcess: mac.thisProcess,
                freshProcess: { mac.freshProcess(payload) })
        }
        #expect(deliver("table+slot 3", enabled: false) == nil)
        #expect(mac.freshProcessesStarted == 0, "no process is started for a driver not there yet")
        mac.driverRunning = true
        #expect(deliver("table+slot 3", enabled: true) == .freshProcess)
        #expect(deliver("table+slot 2", enabled: true) == .freshProcess)
        #expect(mac.received == ["table+slot 3", "table+slot 2"])
    }

    @Test func aDriverThisProcessSeesIsReachedWithoutStartingAProcess() {
        var started = 0
        let route = DriverHandoff.deliver(
            driverEnabled: true, thisProcess: { true }, freshProcess: { started += 1; return true })
        #expect(route == .thisProcess)
        #expect(started == 0)
    }
}

/// An update whose new driver does not start is activated once more, then reported.
@Suite struct DriverUpdateCheckTests {
    @Test func aNewDriverThatStartsEndsTheCheck() {
        var check = DriverUpdateCheck(lookupsPerAttempt: 3)
        #expect(check.looked(driverPresent: false) == .wait)
        #expect(check.looked(driverPresent: true) == .started)
        #expect(!check.activatedAgain)
    }

    @Test func aNewDriverThatNeverStartsIsActivatedOnceMoreThenNeedsARestart() {
        var check = DriverUpdateCheck(lookupsPerAttempt: 3)
        #expect(check.looked(driverPresent: false) == .wait)
        #expect(check.looked(driverPresent: false) == .wait)
        #expect(check.looked(driverPresent: false) == .activateAgain)
        #expect(check.looked(driverPresent: false) == .wait)
        #expect(check.looked(driverPresent: false) == .wait)
        #expect(check.looked(driverPresent: false) == .restartNeeded)
    }

    @Test func activatingOnceMoreCanStartTheDriver() {
        var check = DriverUpdateCheck(lookupsPerAttempt: 2)
        _ = check.looked(driverPresent: false)
        #expect(check.looked(driverPresent: false) == .activateAgain)
        #expect(check.looked(driverPresent: true) == .started)
    }
}
