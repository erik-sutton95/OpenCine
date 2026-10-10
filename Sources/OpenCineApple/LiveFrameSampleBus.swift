#if os(iOS)
    import CoreVideo
    import Foundation
    import Observation
    import OpenCineMedia

    /// One monitor's source publications. A source lease fences replacement and retirement.
    @MainActor @Observable
    public final class LiveFrameSampleBus {
        public enum Role: Sendable { case live, playback }
        public final class Source: @unchecked Sendable {
            fileprivate let role: Role
            private let active = NSLock()
            private var current = true
            nonisolated public var isActive: Bool { active.withLock { current } }
            nonisolated fileprivate func retire() { active.withLock { current = false } }
            public let exposureCeiling: ScopeExposureCeiling
            fileprivate init(_ role: Role, profile: ScopeClipProfile) {
                self.role = role
                exposureCeiling = ScopeExposureCeiling(profile: profile)
            }
        }
        /// One retained picture and its actual publication lease, captured by a native consumer.
        public struct InspectorFrame: @unchecked Sendable {
            public let buffer: CVPixelBuffer
            public let transfer: MonitorTransfer
            public let lease: Source
            private weak var owner: LiveFrameSampleBus?
            private let epoch: UInt64
            @MainActor fileprivate init(
                buffer: CVPixelBuffer, transfer: MonitorTransfer,
                lease: Source, owner: LiveFrameSampleBus
            ) {
                self.buffer = buffer
                self.transfer = transfer
                self.lease = lease
                self.owner = owner
                epoch = owner.inspectorSourceEpoch
            }
            @MainActor public var isCurrent: Bool {
                guard lease.isActive, let owner else { return false }
                return owner.inspectorSourceEpoch == epoch && owner.inspectorLease === lease
            }
        }

        private struct Snapshot {
            var liveSource: Source?
            var playbackSource: Source?
            var bundle = ScopeAssistBundle.empty
            var playbackBundle: ScopeAssistBundle?
            var sourcePixelBuffer: CVPixelBuffer?
            var playbackSourcePixelBuffer: CVPixelBuffer?
            var playbackSourceTransfer: MonitorTransfer = .rec709
            var inspectorSourceEpoch: UInt64 = 0
            var transfer: MonitorTransfer = .rec709
            var reportedTransfer: MonitorTransfer?
            var generation = 0
            var decodedFrames = 0
            var publishedScopes = 0
            var livePublication: UInt64 = 0
            var playbackPublication: UInt64 = 0
        }
        private enum Field: CaseIterable {
            case bundle, playbackBundle, transfer, reportedTransfer, generation, publishedScopes,
                inspectorSourceEpoch
        }
        @ObservationIgnored private var snapshot = Snapshot()
        @ObservationIgnored private var pendingNotifications = Set<Field>()
        @ObservationIgnored private var isNotifying = false
        @ObservationIgnored private var notificationTask: Task<Void, Never>?
        @ObservationIgnored private let profile: ScopeClipProfile
        @ObservationIgnored private let idleCeiling: ScopeExposureCeiling

        public var bundle: ScopeAssistBundle {
            access(keyPath: \.bundle)
            return snapshot.bundle
        }
        public var playbackBundle: ScopeAssistBundle? {
            access(keyPath: \.playbackBundle)
            return snapshot.playbackBundle
        }
        public var sourcePixelBuffer: CVPixelBuffer? { snapshot.sourcePixelBuffer }
        public var playbackSourcePixelBuffer: CVPixelBuffer? { snapshot.playbackSourcePixelBuffer }
        public var playbackSourceTransfer: MonitorTransfer { snapshot.playbackSourceTransfer }
        public var usesPlaybackSource: Bool { snapshot.playbackSource != nil }
        public var inspectorSourceEpoch: UInt64 {
            access(keyPath: \.inspectorSourceEpoch)
            return snapshot.inspectorSourceEpoch
        }
        public var transfer: MonitorTransfer {
            access(keyPath: \.transfer)
            return snapshot.transfer
        }
        public var reportedTransfer: MonitorTransfer? {
            access(keyPath: \.reportedTransfer)
            return snapshot.reportedTransfer
        }
        public var exposureCeiling: ScopeExposureCeiling {
            snapshot.playbackSource?.exposureCeiling ?? snapshot.liveSource?.exposureCeiling
                ?? idleCeiling
        }
        public var generation: Int {
            access(keyPath: \.generation)
            return snapshot.generation
        }
        public var decodedFrames: Int { snapshot.decodedFrames }
        public var publishedScopes: Int {
            access(keyPath: \.publishedScopes)
            return snapshot.publishedScopes
        }

        private var inspectorLease: Source? { snapshot.playbackSource ?? snapshot.liveSource }
        public var inspectorFrame: InspectorFrame? {
            guard let lease = inspectorLease, let source = inspectorSource else { return nil }
            return InspectorFrame(
                buffer: source.buffer, transfer: source.transfer, lease: lease, owner: self)
        }
        public var displayBundle: ScopeAssistBundle {
            usesPlaybackSource ? (playbackBundle ?? .empty) : bundle
        }
        public var inspectorSource: (buffer: CVPixelBuffer, transfer: MonitorTransfer)? {
            if usesPlaybackSource {
                return playbackSourcePixelBuffer.map { ($0, playbackSourceTransfer) }
            }
            return sourcePixelBuffer.map { ($0, transfer) }
        }

        public init(profile: ScopeClipProfile = .init()) {
            self.profile = profile
            idleCeiling = ScopeExposureCeiling(profile: profile)
        }

        /// Commit values and leases before callbacks. Preserve each original setter's notification
        /// intent, including equal bundles, while reentrant publications merge their pending fields.
        private func commit(notifying fields: Set<Field>, _ change: (inout Snapshot) -> Void) {
            var next = snapshot
            change(&next)
            snapshot = next
            pendingNotifications.formUnion(fields)
            drainNotifications()
        }

        private func drainNotifications() {
            guard !isNotifying else { return }
            isNotifying = true
            for field in Field.allCases {
                guard pendingNotifications.remove(field) != nil else { continue }
                switch field {
                case .bundle: withMutation(keyPath: \.bundle) {}
                case .playbackBundle: withMutation(keyPath: \.playbackBundle) {}
                case .transfer: withMutation(keyPath: \.transfer) {}
                case .reportedTransfer: withMutation(keyPath: \.reportedTransfer) {}
                case .generation: withMutation(keyPath: \.generation) {}
                case .publishedScopes: withMutation(keyPath: \.publishedScopes) {}
                case .inspectorSourceEpoch: withMutation(keyPath: \.inspectorSourceEpoch) {}
                }
            }
            isNotifying = false
            // One bounded pass delivers fields not yet visited. Fields added again during that
            // pass get a later notification; their values and source admission are already current.
            if !pendingNotifications.isEmpty, notificationTask == nil {
                notificationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.notificationTask = nil
                    self.drainNotifications()
                }
            }
        }

        private var liveClearNotifications: Set<Field> {
            var fields: Set<Field> = [
                .bundle, .transfer, .reportedTransfer, .generation, .publishedScopes,
            ]
            if snapshot.playbackSource == nil { fields.insert(.inspectorSourceEpoch) }
            return fields
        }

        private static func clearPlayback(_ state: inout Snapshot) {
            state.playbackBundle = nil
            state.playbackSourcePixelBuffer = nil
            state.playbackSourceTransfer = .rec709
            state.inspectorSourceEpoch &+= 1
        }
        private static func clearLive(_ state: inout Snapshot) {
            state.bundle = .empty
            state.sourcePixelBuffer = nil
            state.transfer = .rec709
            state.reportedTransfer = nil
            state.generation = 0
            state.decodedFrames = 0
            state.publishedScopes = 0
            if state.playbackSource == nil { state.inspectorSourceEpoch &+= 1 }
        }

        public func openSource(_ role: Role) -> Source {
            let source = Source(role, profile: profile)
            switch role {
            case .live:
                snapshot.liveSource?.retire()
                commit(notifying: liveClearNotifications) {
                    Self.clearLive(&$0)
                    $0.liveSource = source
                    $0.livePublication &+= 1
                }
            case .playback:
                snapshot.playbackSource?.retire()
                commit(notifying: [.playbackBundle, .inspectorSourceEpoch]) {
                    Self.clearPlayback(&$0)
                    $0.playbackSource = source
                    $0.playbackPublication &+= 1
                }
            }
            return source
        }
        public func isCurrent(_ source: Source?) -> Bool {
            guard let source else { return false }
            switch source.role {
            case .live: return snapshot.liveSource === source
            case .playback: return snapshot.playbackSource === source
            }
        }
        public func closeSource(_ source: Source?) {
            guard let source, isCurrent(source) else { return }
            source.retire()
            switch source.role {
            case .live:
                commit(notifying: liveClearNotifications) {
                    $0.liveSource = nil
                    Self.clearLive(&$0)
                    $0.livePublication &+= 1
                }
            case .playback:
                commit(notifying: [.playbackBundle, .inspectorSourceEpoch]) {
                    $0.playbackSource = nil
                    Self.clearPlayback(&$0)
                    $0.playbackPublication &+= 1
                }
            }
        }
        public func clearPlaybackSource(_ source: Source?) {
            guard let source, source.role == .playback, isCurrent(source) else { return }
            commit(notifying: [.playbackBundle, .inspectorSourceEpoch]) {
                Self.clearPlayback(&$0)
                $0.playbackPublication &+= 1
            }
        }
        public func noteDecodedFrame(_ source: Source?) {
            guard let source, source.role == .live, isCurrent(source) else { return }
            snapshot.decodedFrames += 1
        }
        /// Raw picture retention does not tick scope observation. One bundle advances one revision.
        @discardableResult public func publish(
            _ owner: Source?, source: CVPixelBuffer?, transfer: MonitorTransfer,
            reportedTransfer: MonitorTransfer? = nil, bundle: ScopeAssistBundle?
        ) -> Bool {
            guard let owner, isCurrent(owner) else { return false }
            var admitted: UInt64 = 0
            switch owner.role {
            case .live:
                var fields: Set<Field> = [.transfer, .reportedTransfer]
                if bundle != nil { fields.formUnion([.bundle, .publishedScopes, .generation]) }
                commit(notifying: fields) {
                    $0.livePublication &+= 1
                    admitted = $0.livePublication
                    if let source { $0.sourcePixelBuffer = source }
                    $0.transfer = transfer
                    $0.reportedTransfer = reportedTransfer
                    if let bundle {
                        $0.bundle = bundle
                        $0.publishedScopes += 1
                        $0.generation += 1
                    }
                }
                return isCurrent(owner) && snapshot.livePublication == admitted
            case .playback:
                commit(notifying: bundle == nil ? [] : [.playbackBundle]) {
                    $0.playbackPublication &+= 1
                    admitted = $0.playbackPublication
                    if let source {
                        $0.playbackSourcePixelBuffer = source
                        $0.playbackSourceTransfer = transfer
                    }
                    if let bundle { $0.playbackBundle = bundle }
                }
                return isCurrent(owner) && snapshot.playbackPublication == admitted
            }
        }
    }
#endif
