#if os(iOS)
    /// Original clock flag retained at the migration boundary. Shared clock placement uses DISP.
    @MainActor public protocol LegacyLiveClockAvailability {
        @available(*, deprecated, message: "Read the snapshot timecode declaration")
        var timecodeAvailable: Bool { get }
    }

    public extension LiveChromeHost {
        var timecodeAvailable: Bool {
            guard let snapshot = control.snapshot else { return false }
            return snapshot.capabilities.timecode == .supported
        }
    }
#endif
