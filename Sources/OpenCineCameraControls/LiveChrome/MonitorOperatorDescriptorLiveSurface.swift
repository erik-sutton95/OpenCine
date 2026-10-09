#if os(iOS)
import OpenCineAppKit
import SwiftUI

/// Compatibility entry for descriptor-based integrations. Every region is rendered by the
/// same live owner used by the legacy camera host and descriptor-only operator scene.
public typealias MonitorOperatorDescriptorLiveSurface<Host: ChromeEditHost, Key: Hashable,
    Looks: MonitorLookProvider, Picture: View, CameraPanel: View, PhotoRelease: View,
    Preview: View, LookMenu: View> = MonitorOperatorLiveBody<Host, Key, Never,
        Looks, Picture, CameraPanel, PhotoRelease, Preview, LookMenu>
#endif
