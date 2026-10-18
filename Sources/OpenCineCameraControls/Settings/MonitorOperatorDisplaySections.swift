#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import SwiftUI

/// Owns the common display rows, resets and clean pins over existing namespaced values, one
/// section per DISP mode the source offers.
public struct MonitorOperatorDisplaySections<Looks: MonitorLookProvider>: View {
    private let modes: [MonitorDisplayMode]
    private let chrome: (MonitorDisplayMode) -> Binding<MonitorDisplayChrome>
    private let assist: MonitorAssistState<Looks>
    private let available: Set<MonitorDisplayChrome.Section>
    private let edit: ((MonitorDisplayMode) -> Void)?
    private let feedback: () -> Void

    public init(modes: [MonitorDisplayMode], chrome: @escaping (MonitorDisplayMode) -> Binding<MonitorDisplayChrome>,
        assist: MonitorAssistState<Looks>, available: Set<MonitorDisplayChrome.Section>,
        edit: ((MonitorDisplayMode) -> Void)?, feedback: @escaping () -> Void) {
        self.modes = modes; self.chrome = chrome; self.assist = assist
        self.available = available; self.edit = edit; self.feedback = feedback
    }

    public var body: some View {
        MonitorDisplaySections(sections: modes.map { mode in
            let chrome = chrome(mode)
            return MonitorDisplaySection(id: mode.rawValue, title: mode.settingsTitle,
                caption: mode.settingsCaption,
                reset: { feedback(); chrome.wrappedValue = MonitorDisplayChrome.defaults(for: mode) },
                editHint: "Opens the monitor with an eye on each element you can show or hide.",
                edit: edit.map { action in { action(mode) } },
                unavailableEditHelp: "Connect to arrange this on the monitor.",
                visibility: Self.order.filter { available.contains($0) && MonitorDisplayChrome.isConfigurable($0, in: mode) }
                    .map { section in
                    MonitorDisplayToggle(id: mode.rawValue + "." + Self.title(section),
                        title: Self.title(section), isOn: chrome.wrappedValue.isVisible(section),
                        help: Self.help(section)) {
                        feedback(); chrome.wrappedValue.toggle(section)
                    }
                }, pinsTitle: "View assists that stay on in clean view",
                pins: mode == .clean ? MonitorAssistSelection.cleanPinCases.map { tool in
                    MonitorDisplayToggle(id: "clean.pin." + tool.rawValue, title: tool.displaySettingsTitle,
                        isOn: assist.cleanViewPinnedTools.contains(tool),
                        accessibilityLabel: "Keep \(tool.displaySettingsTitle) in clean view") {
                        feedback(); assist.toggleCleanViewPin(tool)
                    }
                } : []
            )
        })
    }

    private static var order: [MonitorDisplayChrome.Section] {
        [.statusBar, .toolBar, .cameraValues, .lockButton, .batteries, .recReadout, .timecode,
         .format, .codec, .color, .storage, .fps, .railRecord, .railMedia, .railSettings, .zoomChip,
         .gimbalStick, .focusBox]
    }
    private static func title(_ section: MonitorDisplayChrome.Section) -> String {
        section == .focusBox ? "AF Box" : section.title
    }
    private static func help(_ section: MonitorDisplayChrome.Section) -> String {
        switch section {
        case .statusBar: "REC, timecode, format, and FPS along the top of the feed."
        case .toolBar: "The view-assist strip under the feed."
        case .cameraValues: "ISO, shutter, white balance, and the rest of the capture strip."
        case .lockButton: "Side-rail lock. Remounts while the interface is locked."
        case .batteries: "Phone and camera battery cluster."
        case .recReadout: "Standby / recording chip on the status bar."
        case .timecode: "Running timecode on the status bar."
        case .format: "Recording resolution and frame rate."
        case .codec: "Recording codec chip on the status bar."
        case .color: "Color mode chip on the status bar."
        case .storage: "Remaining media time on the status bar."
        case .fps: "Live-view rate and link bars."
        case .railRecord: "Rail record lamp. Stays available while rolling."
        case .railMedia: "Rail media button."
        case .railSettings: "Rail settings button. Always an escape hatch."
        case .zoomChip: "Live zoom readout on the feed."
        case .gimbalStick: "On-screen gimbal stick."
        case .focusBox: "Focus and face-tracking brackets on the feed."
        }
    }
}
#endif
