import OpenCineNikon

/// Captures only an already-established Android owner; this never opens or chooses a camera.
public enum NikonAndroidFocusRackAccess {
    /// The authority closure is thread-safe and revoked before lifecycle invalidation is queued.
    /// The returned access never retains a JNI environment or calls Kotlin from its worker queue.
    public static func capture(
        connectionOwner: Int64, isAdmitted: @escaping @Sendable () -> Bool
    ) -> NikonFocusRackAccess? {
        capture(connectionOwner: connectionOwner, cadence: .standard, isAdmitted: isAdmitted)
    }

    /// Opts this controller into a cadence while preserving existing callers' defaults.
    public static func capture(
        connectionOwner: Int64, cadence: NikonFocusRackCadence,
        isAdmitted: @escaping @Sendable () -> Bool
    ) -> NikonFocusRackAccess? {
        #if os(Android)
            return captureAndroidFocusRackAccess(
                connectionOwner: connectionOwner, cadence: cadence, isAdmitted: isAdmitted)
        #else
            return nil
        #endif
    }
}
