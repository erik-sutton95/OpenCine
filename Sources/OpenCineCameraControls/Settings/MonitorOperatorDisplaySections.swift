#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import SwiftUI

/// Owns the common display rows, resets and clean pins over existing namespaced values.
public struct MonitorOperatorDisplaySections<Looks: MonitorLookProvider>: View {
    @Binding private var live: MonitorDisplayChrome
    @Binding private var clean: MonitorDisplayChrome
    private let assist: MonitorAssistState<Looks>
    private let available: Set<MonitorDisplayChrome.Section>
    private let edit: ((MonitorDisplayMode) -> Void)?
    private let feedback: () -> Void

    public init(live: Binding<MonitorDisplayChrome>, clean: Binding<MonitorDisplayChrome>,
        assist: MonitorAssistState<Looks>,
        available: Set<MonitorDisplayChrome.Section> = Set(MonitorDisplayChrome.Section.allCases),
        edit: ((MonitorDisplayMode) -> Void)? = nil, feedback: @escaping () -> Void = {}) {
        _live = live; _clean = clean; self.assist = assist
        self.available = available; self.edit = edit; self.feedback = feedback
    }

    public var body: some View {
        MonitorDisplaySections(sections: MonitorDisplayMode.allCases.map { mode in
            let chrome = mode == .clean ? $clean : $live
            return MonitorDisplaySection(id: mode.rawValue, title: mode.settingsTitle,
                caption: mode.settingsCaption,
                reset: { feedback(); chrome.wrappedValue = mode == .clean ? .cleanDefaults : .liveDefaults },
                editHint: "Opens the monitor with an eye on each element you can show or hide.",
                edit: edit.map { action in { action(mode) } },
                unavailableEditHelp: "Connect to arrange this on the monitor.",
                visibility: Self.order.filter(available.contains).map { section in
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
                } : [], style: .controls)
        })
    }

    private static var order: [MonitorDisplayChrome.Section] {
        [.statusBar, .toolBar, .cameraValues, .lockButton, .batteries, .recReadout, .timecode,
         .format, .color, .storage, .fps, .railRecord, .railMedia, .railSettings, .zoomChip,
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
