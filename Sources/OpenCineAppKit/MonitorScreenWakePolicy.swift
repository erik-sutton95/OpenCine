import Foundation

/// The operator preference applies to every active foreground surface.
public enum MonitorScreenWakePolicy {
    public static func keepAwake(enabled: Bool, sceneActive: Bool) -> Bool {
        enabled && sceneActive
    }
}
