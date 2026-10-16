import Foundation

/// The operator's feed-sharing choices under the app's existing keys: whether this monitor shares
/// its feed, whether watchers may request control, and the watcher relay priority ceiling
/// (0 is the highest quality). Reads never write; priority clamps on read and on write.
public final class MonitorSharingPreferences: @unchecked Sendable {
    public struct Keys: Sendable {
        public let shareThisFeed: String
        public let controlRequests: String
        public let broadcastPriority: String

        public init(shareThisFeed: String, controlRequests: String, broadcastPriority: String) {
            let keys = [shareThisFeed, controlRequests, broadcastPriority]
            precondition(keys.allSatisfy { !$0.isEmpty } && Set(keys).count == keys.count)
            self.shareThisFeed = shareThisFeed
            self.controlRequests = controlRequests
            self.broadcastPriority = broadcastPriority
        }

        /// The keys camera apps already use: `<prefix>.ShareThisFeed` and so on.
        public init(prefix: String) {
            self.init(shareThisFeed: prefix + ".ShareThisFeed", controlRequests: prefix + ".ControlRequests",
                broadcastPriority: prefix + ".BroadcastPriority")
        }
    }

    public struct Defaults: Sendable {
        public var shareThisFeed: Bool
        public var controlRequests: Bool
        public var broadcastPriority: Int

        public init(shareThisFeed: Bool = false, controlRequests: Bool = true, broadcastPriority: Int = 0) {
            self.shareThisFeed = shareThisFeed
            self.controlRequests = controlRequests
            self.broadcastPriority = broadcastPriority
        }
    }

    // Configuration is immutable. UserDefaults synchronizes its individual reads and writes.
    private let storage: UserDefaults
    private let keys: Keys
    private let defaults: Defaults
    private let priorityRange: ClosedRange<Int>

    public init(
        storage: UserDefaults, keys: Keys, defaults: Defaults = .init(), priorityRange: ClosedRange<Int>
    ) {
        self.storage = storage
        self.keys = keys
        self.defaults = defaults
        self.priorityRange = priorityRange
    }

    public var shareThisFeed: Bool {
        get { bool(keys.shareThisFeed, fallback: defaults.shareThisFeed) }
        set { storage.set(newValue, forKey: keys.shareThisFeed) }
    }
    public var controlRequests: Bool {
        get { bool(keys.controlRequests, fallback: defaults.controlRequests) }
        set { storage.set(newValue, forKey: keys.controlRequests) }
    }
    public var broadcastPriority: Int {
        get {
            let stored = storage.object(forKey: keys.broadcastPriority) == nil
                ? defaults.broadcastPriority : storage.integer(forKey: keys.broadcastPriority)
            return clamped(stored)
        }
        set { storage.set(clamped(newValue), forKey: keys.broadcastPriority) }
    }

    private func bool(_ key: String, fallback: Bool) -> Bool {
        storage.object(forKey: key) == nil ? fallback : storage.bool(forKey: key)
    }

    private func clamped(_ value: Int) -> Int {
        min(max(priorityRange.lowerBound, value), priorityRange.upperBound)
    }
}
