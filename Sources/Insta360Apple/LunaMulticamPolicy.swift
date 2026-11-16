import Foundation
import OpenCineCore

/// Which saved Luna routes may join a multicam group (Kotlin `LunaMulticamPolicy`, same rules).
/// Several Lunas share one network only in station role: a router's Wi-Fi or this phone's
/// hotspot. The phone holds one camera access point at a time, so that route never joins. The
/// member limit is the app's `ResourceBudget`, not a Luna constant. This never joins a network or
/// sends a command.
public enum LunaMulticamPolicy {
    /// Qualification for opening `route` as a member next to `members`. `device` is the camera's
    /// durable identity when known; nil skips the member check (the connect still checks the
    /// camera's serial).
    public static func qualification(
        route: SavedRoute?, device: CameraDeviceID?, members: Set<CameraDeviceID>
    ) -> MulticamQualification {
        guard let route else { return .refused(.notReachable) }
        switch route.kind {
        case .infrastructureNetwork, .phoneHotspot:
            if let device, members.contains(device) { return .refused(.alreadyMember) }
            return .qualified
        case .cameraAccessPoint, .usb, .captureDevice:
            return .refused(.unsupportedConfiguration)
        }
    }
}
