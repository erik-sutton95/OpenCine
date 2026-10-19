import Foundation
import OpenCineDJI

/// Injectable monotonic time. Production uses the existing donor timing bands.
@MainActor public struct DjiAppleMediaTiming {
    public var now: () -> TimeInterval
    public var sleep: (Duration) async throws -> Void
    public init(
        now: @escaping () -> TimeInterval,
        sleep: @escaping (Duration) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }
    public static var continuous: Self {
        .init(
            now: { ProcessInfo.processInfo.systemUptime }, sleep: { try await Task.sleep(for: $0) })
    }
    func seconds(_ duration: Duration) -> TimeInterval {
        let value = duration.components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

/// The real bounded post-gallery loop. Host facts/actions retain current native authority.
@MainActor public enum DjiAppleMediaLiveReturn {
    public enum Result: Equatable, Sendable { case restored, exhausted, superseded }

    public static func run(
        timeout: Duration = .seconds(FeedWatchdog.decoderRepairDeadline),
        timing: DjiAppleMediaTiming = .continuous,
        isCurrent: () -> Bool,
        inPlayback: () -> Bool,
        pictureFresh: () -> Bool,
        exitPlayback: () async -> Bool,
        enableLiveView: () -> Bool
    ) async -> Result {
        // The picture budget starts with the first live-view request. Exiting playback is
        // bounded by `maxExitAttempts`; a slow gallery exit must not spend the picture's time.
        var deadline: TimeInterval?
        var lastEnableAt: TimeInterval?
        var attempt = 1
        var exitAcknowledged = false
        var enableSent = false
        while !Task.isCancelled, isCurrent() {
            let now = timing.now()
            switch MediaLiveResume.action(
                attempt: attempt, inPlayback: inPlayback(),
                exitAcknowledged: exitAcknowledged, pictureFresh: pictureFresh(),
                enableSent: enableSent, deadlineExpired: deadline.map { now >= $0 } ?? false,
                keyframeResendDue: lastEnableAt.map {
                    now - $0 >= FeedWatchdog.keyframeResendInterval
                } ?? false)
            {
            case .done: return .restored
            case .exhausted: return .exhausted
            case .exitPlayback:
                let acknowledged = await exitPlayback()
                // An exit completion that was retired while suspended cannot send an enable.
                guard !Task.isCancelled, isCurrent() else { return .superseded }
                exitAcknowledged = acknowledged || exitAcknowledged
                attempt += 1
                do { try await timing.sleep(.milliseconds(180)) } catch { return .superseded }
            case .enableLiveView:
                deadline = deadline ?? now + timing.seconds(timeout)
                let accepted = enableLiveView()
                enableSent = accepted || enableSent
                // A refused resend must not delay the next one by another keyframe interval.
                if accepted { lastEnableAt = now }
                do { try await timing.sleep(.milliseconds(100)) } catch { return .superseded }
            case .waitForPicture:
                do { try await timing.sleep(.milliseconds(100)) } catch { return .superseded }
            }
        }
        return .superseded
    }
}

/// A current source's native return permit, never constructed by generic UI visibility.
@MainActor public struct DjiAppleMediaReturnAuthority {
    public var isCurrent: () -> Bool
    public var inPlayback: () -> Bool
    public var pictureFresh: () -> Bool
    public var exitPlayback: () async -> Bool
    public var enableLiveView: () -> Bool
    public var completed: (DjiAppleMediaLiveReturn.Result) -> Void
    public init(
        isCurrent: @escaping () -> Bool, inPlayback: @escaping () -> Bool,
        pictureFresh: @escaping () -> Bool, exitPlayback: @escaping () async -> Bool,
        enableLiveView: @escaping () -> Bool,
        completed: @escaping (DjiAppleMediaLiveReturn.Result) -> Void
    ) {
        self.isCurrent = isCurrent
        self.inPlayback = inPlayback
        self.pictureFresh = pictureFresh
        self.exitPlayback = exitPlayback
        self.enableLiveView = enableLiveView
        self.completed = completed
    }
}
