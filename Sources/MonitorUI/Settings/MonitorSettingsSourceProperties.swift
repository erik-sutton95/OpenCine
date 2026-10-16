#if os(iOS)
import SwiftUI

/// Source-specific settings keep wire choices and reported values outside common UI policy.
public struct MonitorSettingsSourceProperty: Identifiable {
    public enum Value {
        case choice(MonitorMotionChoiceSetting)
        case toggle(MonitorMotionToggleSetting)
        case reported(String)
        case native(AnyView)
    }
    public let id: String
    public let title: String
    public let help: String
    public let value: Value
    public let compact: Bool
    public init(id: String, title: String, help: String, value: Value, compact: Bool = false) {
        self.id = id; self.title = title; self.help = help; self.value = value; self.compact = compact
    }
}

public struct MonitorSettingsSourceGroup: Identifiable {
    public let id: String
    public let title: String
    public let properties: [MonitorSettingsSourceProperty]
    public init(id: String, title: String, properties: [MonitorSettingsSourceProperty]) {
        self.id = id; self.title = title; self.properties = properties
    }
}

/// The remote shutter row: the host's stored choice with the owner's title and help
/// (`MonitorSettingsRemoteShutter.volumeButtons(enabled:)` in OpenCineAppKitApple).
public struct MonitorSettingsRemoteShutter {
    public let enabled: Binding<Bool>
    public let title: String
    public let help: String
    public init(enabled: Binding<Bool>, title: String, help: String) {
        self.enabled = enabled; self.title = title; self.help = help
    }
}

/// The auto-rotate row, for a source that reports the camera body's orientation.
public struct MonitorSettingsAutoRotate {
    public let enabled: Binding<Bool>
    public let help: String
    public init(enabled: Binding<Bool>, help: String) {
        self.enabled = enabled; self.help = help
    }
}

/// Input and orientation: each capability is declared on its own (A2-32), so an app offers a
/// remote shutter without inventing a rotation choice, and the reverse.
public struct MonitorSettingsInputSource {
    public let remoteShutter: MonitorSettingsRemoteShutter?
    public let autoRotate: MonitorSettingsAutoRotate?
    public init(remoteShutter: MonitorSettingsRemoteShutter? = nil, autoRotate: MonitorSettingsAutoRotate? = nil) {
        self.remoteShutter = remoteShutter; self.autoRotate = autoRotate
    }
}

public struct MonitorSettingsWatchersSource {
    public struct Request {
        public let name: String
        public let help: String
        public let decline: () -> Void
        public let grant: () -> Void
        public init(name: String, help: String, decline: @escaping () -> Void, grant: @escaping () -> Void) {
            self.name = name; self.help = help; self.decline = decline; self.grant = grant
        }
    }
    public struct Holder {
        public let name: String
        public let help: String
        public let reclaim: () -> Void
        public init(name: String, help: String, reclaim: @escaping () -> Void) {
            self.name = name; self.help = help; self.reclaim = reclaim
        }
    }
    public let watching: String
    public let watchingHelp: String
    public let request: Request?
    public let holder: Holder?
    public init(watching: String, watchingHelp: String, request: Request? = nil, holder: Holder? = nil) {
        self.watching = watching; self.watchingHelp = watchingHelp; self.request = request; self.holder = holder
    }
}

/// Common row/help/control assembly; native content is limited to one property control.
public struct MonitorSettingsSourceGroups: View {
    private let groups: [MonitorSettingsSourceGroup]
    @State private var revision = 0
    public init(groups: [MonitorSettingsSourceGroup]) { self.groups = groups }
    public var body: some View {
        let _ = revision
        ForEach(groups) { group in
            MonitorSettingsRowCard(title: group.title) {
                ForEach(group.properties) { property in
                    row(property, first: group.properties.first?.id == property.id)
                }
            }
        }
    }
    @ViewBuilder private func row(_ property: MonitorSettingsSourceProperty, first: Bool) -> some View {
        switch property.value {
        case .choice(let choice):
            MonitorSettingsInlineRow(title: property.title, help: property.help, showTopDivider: !first) {
                MonitorSegmentedControl(options: choice.options,
                    selection: Binding(get: { choice.selection.wrappedValue }, set: { choice.selection.wrappedValue = $0; revision += 1 }),
                    compact: property.compact, title: { $0 }, onSelectionFeedback: choice.feedback)
                    .buttonStyle(MonitorSettingsButtonStyle())
            }
        case .toggle(let toggle):
            MonitorSettingsSwitchInlineRow(title: property.title, help: property.help, showTopDivider: !first,
                isOn: toggle.value.wrappedValue, feedback: toggle.feedback) { toggle.value.wrappedValue.toggle(); revision += 1 }
        case .reported(let value):
            MonitorSettingsInlineRow(title: property.title, help: property.help, showTopDivider: !first) { MonitorSettingsValueText(value: value) }
        case .native(let content):
            MonitorSettingsInlineRow(title: property.title, help: property.help, showTopDivider: !first) { content }
        }
    }
}
#endif
