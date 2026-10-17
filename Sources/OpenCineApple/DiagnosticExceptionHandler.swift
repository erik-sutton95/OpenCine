#if canImport(ObjectiveC)
    import Foundation

    /// Owns the process-wide OS exception hook. The host supplies its journal action.
    /// Replacing that action preserves the original handler chain and any later OS handler.
    public enum DiagnosticExceptionHandler {
        private static let registration = ExceptionRegistration()

        public static func install(record: @escaping @Sendable (NSException) -> Void) {
            registration.install(record: record)
        }

        fileprivate static func receive(_ exception: NSException) {
            registration.receive(exception)
        }
    }

    private final class ExceptionRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var record: (@Sendable (NSException) -> Void)?
        private var previous: NSUncaughtExceptionHandler?
        private var installed = false

        func install(record: @escaping @Sendable (NSException) -> Void) {
            lock.withLock {
                self.record = record
                guard !installed else { return }
                previous = NSGetUncaughtExceptionHandler()
                installed = true
                NSSetUncaughtExceptionHandler { exception in
                    DiagnosticExceptionHandler.receive(exception)
                }
            }
        }

        func receive(_ exception: NSException) {
            let handlers = lock.withLock { (record, previous) }
            // Journaling or a prior handler can replace the host. Neither runs under the lock.
            handlers.0?(exception)
            handlers.1?(exception)
        }
    }
#endif
