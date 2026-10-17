#if canImport(ObjectiveC)
    import Foundation
    import Testing
    @testable import OpenCineApple

    /// SIMULATED exception delivery through the real OS handler, without raising an exception.
    @Suite(.serialized) struct DiagnosticExceptionHandlerTests {
        @Test func replacementRecordsTheCurrentHostAndChainsTheOriginalHandlerOnce() throws {
            let original = NSGetUncaughtExceptionHandler()
            defer { NSSetUncaughtExceptionHandler(original) }
            diagnosticPreviousEvents.reset()
            NSSetUncaughtExceptionHandler { exception in
                diagnosticPreviousEvents.append(exception.name.rawValue)
            }

            let first = ExceptionEvents()
            let replacement = ExceptionEvents()
            DiagnosticExceptionHandler.install { exception in
                first.append(exception.name.rawValue)
                // A host can replace its registration while journaling. Delivery must not
                // hold the installation lock or chain the platform callback to itself.
                DiagnosticExceptionHandler.install { replacement.append($0.name.rawValue) }
            }
            let handler = try #require(NSGetUncaughtExceptionHandler())
            handler(NSException(name: .init("SIMULATEDFirst"), reason: nil, userInfo: nil))
            #expect(first.values == ["SIMULATEDFirst"])
            #expect(replacement.values.isEmpty)
            #expect(diagnosticPreviousEvents.values == ["SIMULATEDFirst"])

            handler(NSException(name: .init("SIMULATEDReplacement"), reason: nil, userInfo: nil))
            #expect(first.values == ["SIMULATEDFirst"])
            #expect(replacement.values == ["SIMULATEDReplacement"])
            #expect(diagnosticPreviousEvents.values == ["SIMULATEDFirst", "SIMULATEDReplacement"])

            // A handler installed later owns the OS slot. Updating the diagnostic host must
            // preserve that handler rather than overwrite it or introduce a chaining cycle.
            NSSetUncaughtExceptionHandler { exception in
                diagnosticPreviousEvents.append("later:" + exception.name.rawValue)
            }
            DiagnosticExceptionHandler.install { replacement.append("updated:" + $0.name.rawValue) }
            let later = try #require(NSGetUncaughtExceptionHandler())
            later(NSException(name: .init("SIMULATEDLater"), reason: nil, userInfo: nil))
            #expect(diagnosticPreviousEvents.values == [
                "SIMULATEDFirst", "SIMULATEDReplacement", "later:SIMULATEDLater",
            ])
            #expect(replacement.values == ["SIMULATEDReplacement"])
        }
    }

    private let diagnosticPreviousEvents = ExceptionEvents()

    private final class ExceptionEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []
        var values: [String] { lock.withLock { events } }
        func append(_ value: String) { lock.withLock { events.append(value) } }
        func reset() { lock.withLock { events.removeAll() } }
    }
#endif
