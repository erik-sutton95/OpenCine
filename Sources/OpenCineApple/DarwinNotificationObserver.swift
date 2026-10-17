#if os(iOS)
    import CoreFoundation
    import Foundation

    /// Observes system-wide Darwin notifications by name (a test runner posting into the app).
    /// The handler runs on the posting thread; keep the observer alive while it should listen.
    public final class DarwinNotificationObserver: @unchecked Sendable {
        private let handler: @Sendable (String) -> Void

        public init(names: [String], handler: @escaping @Sendable (String) -> Void) {
            self.handler = handler
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let observer = Unmanaged.passUnretained(self).toOpaque()
            for name in names {
                CFNotificationCenterAddObserver(
                    center, observer, darwinNotificationCallback, name as CFString, nil,
                    .deliverImmediately)
            }
        }

        deinit {
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
        }

        fileprivate func deliver(_ name: String) { handler(name) }
    }

    private let darwinNotificationCallback: CFNotificationCallback = { _, observer, name, _, _ in
        guard let observer else { return }
        let key = name.map { $0.rawValue as String } ?? ""
        Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue().deliver(key)
    }
#endif
