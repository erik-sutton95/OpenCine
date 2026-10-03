#if os(iOS)
    import SwiftUI

    /// Known local input/display choices. The host retains persistence and input arming policy.
    public struct MonitorInputOrientationSettings: View {
        private let remoteShutter: Binding<Bool>?
        private let remoteTitle: String
        private let remoteHelp: String?
        private let remoteCaption: String?
        private let autoRotateFeed: Binding<Bool>?
        private let rotationTitle: String
        private let rotationHelp: String
        private let feedback: () -> Void

        public init(
            remoteShutter: Binding<Bool>? = nil, remoteTitle: String = "Remote shutter",
            remoteHelp: String? = nil, remoteCaption: String? = nil,
            autoRotateFeed: Binding<Bool>? = nil, rotationTitle: String = "Auto-Rotate Feed",
            rotationHelp: String, feedback: @escaping () -> Void = {}
        ) {
            self.remoteShutter = remoteShutter
            self.remoteTitle = remoteTitle
            self.remoteHelp = remoteHelp
            self.remoteCaption = remoteCaption
            self.autoRotateFeed = autoRotateFeed
            self.rotationTitle = rotationTitle
            self.rotationHelp = rotationHelp
            self.feedback = feedback
        }

        public var body: some View {
            if remoteShutter != nil || autoRotateFeed != nil {
                MonitorSettingsRowCard(title: "Input & orientation") {
                    if let remoteShutter {
                        MonitorSettingsSwitchInlineRow(
                            title: remoteTitle, help: remoteHelp,
                            showTopDivider: false, isOn: remoteShutter.wrappedValue,
                            feedback: feedback
                        ) {
                            remoteShutter.wrappedValue.toggle()
                        }
                        if let remoteCaption {
                            Text(remoteCaption).font(MonitorTheme.font(10.5)).foregroundStyle(
                                MonitorTheme.muted
                            )
                            .fixedSize(horizontal: false, vertical: true).padding(.bottom, 6)
                        }
                    }
                    if let autoRotateFeed {
                        MonitorSettingsSwitchInlineRow(
                            title: rotationTitle, help: rotationHelp,
                            showTopDivider: remoteShutter != nil, isOn: autoRotateFeed.wrappedValue,
                            feedback: feedback
                        ) {
                            autoRotateFeed.wrappedValue.toggle()
                        }
                    }
                }
            }
        }
    }
#endif
