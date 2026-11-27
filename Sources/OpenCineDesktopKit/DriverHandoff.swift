import Foundation

/// How the dock reaches the driver's inputs to hand over the slot table and the selection.
///
/// Core Media IO in a process that is already running can miss a driver that appears after the
/// process first looked: after a driver update the dock kept its old device list and never saw the
/// new inputs, while every process started later saw them at once. So when this process cannot see
/// the driver, a short-lived process (the dock's own executable) looks and hands over instead.
public enum DriverHandoff {
    public enum Route: Equatable, Sendable {
        case thisProcess
        case freshProcess
    }

    /// Tries this process first, then a fresh one while the driver is known to be installed and
    /// enabled (no process is started for a driver that is not there yet). Each closure returns
    /// true when it saw the driver and handed over. `nil` when neither reached it.
    public static func deliver(
        driverEnabled: Bool, thisProcess: () -> Bool, freshProcess: () -> Bool
    ) -> Route? {
        if thisProcess() { return .thisProcess }
        guard driverEnabled else { return nil }
        return freshProcess() ? .freshProcess : nil
    }
}

/// Whether an updated driver really started. macOS can report a driver update as finished while
/// the new driver never launches: when the old driver was still running, its launch job was still
/// being removed as the new one was submitted, and the submission failed ("Operation already in
/// progress"). After an update the dock looks for the driver's inputs once a second; if they do
/// not appear it activates once more (the old driver is gone by then, so the race cannot recur),
/// and if they still do not appear it asks for a restart, which always starts the new driver.
public struct DriverUpdateCheck: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Look again in a second.
        case wait
        /// The new driver is running.
        case started
        /// Submit the activation again.
        case activateAgain
        /// Tell the owner to restart the Mac.
        case restartNeeded
    }

    public let lookupsPerAttempt: Int
    public private(set) var activatedAgain = false
    private var lookups = 0

    public init(lookupsPerAttempt: Int = 15) {
        self.lookupsPerAttempt = max(1, lookupsPerAttempt)
    }

    /// The result of one look for the driver's inputs from a fresh process.
    public mutating func looked(driverPresent: Bool) -> Action {
        if driverPresent { return .started }
        lookups += 1
        guard lookups >= lookupsPerAttempt else { return .wait }
        lookups = 0
        if activatedAgain { return .restartNeeded }
        activatedAgain = true
        return .activateAgain
    }
}
