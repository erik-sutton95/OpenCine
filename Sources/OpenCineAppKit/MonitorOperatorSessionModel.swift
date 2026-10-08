import Foundation
import MonitorPresentation
import Observation

/// Owns the monitor's display editor, reachable settings and connect-tap arming lifetime.
/// The shell retains the camera; this owner closes presentation without sending a command.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorOperatorSessionModel<Looks: MonitorLookProvider> {
    public var live: MonitorDisplayChrome { didSet { preferences.live = live } }
    public var clean: MonitorDisplayChrome { didSet { preferences.clean = clean } }
    public var settingsTab: MonitorSettingsTab = .link
    public var editingMode: MonitorDisplayMode? {
        get { displaySession.editingMode }
        set { displaySession.editingMode = newValue }
    }
    public var returnedMode: MonitorDisplayMode? {
        get { displaySession.returnedMode }
        set { displaySession.returnedMode = newValue }
    }
    public private(set) var interactive = true

    private let shell: ShellModel
    private let assist: MonitorAssistState<Looks>
    private let preferences: MonitorDisplayPreferences
    private let displaySession = MonitorDisplaySession<MonitorDisplayMode>(mode: .live)
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private var source: UUID?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var armTask: Task<Void, Never>?

    public init(shell: ShellModel, assist: MonitorAssistState<Looks>,
        display: MonitorDisplayPreferences,
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.shell = shell; self.assist = assist; preferences = display; self.sleep = sleep
        live = display.live; clean = display.clean
    }

    public var mode: MonitorDisplayMode { assist.clean ? .clean : .live }
    public var chrome: MonitorDisplayChrome { chrome(for: mode) }
    public var isEditing: Bool { editingMode != nil }

    public func chrome(for mode: MonitorDisplayMode) -> MonitorDisplayChrome {
        mode == .clean ? clean : live
    }

    public func mounts(_ section: MonitorDisplayChrome.Section) -> Bool {
        if editingMode == mode, MonitorDisplayChrome.isConfigurable(section, in: mode) { return true }
        if section == .railSettings, !live.railSettings, !clean.railSettings { return true }
        return chrome.isVisible(section)
    }

    public func toggle(_ section: MonitorDisplayChrome.Section, in mode: MonitorDisplayMode) {
        if mode == .clean { clean.toggle(section) } else { live.toggle(section) }
    }

    public func beginEditing(_ mode: MonitorDisplayMode) {
        shell.dismissCover()
        assist.clean = mode == .clean
        displaySession.beginEditing(mode)
    }

    public func finishEditing() {
        guard displaySession.finishEditing(order: MonitorDisplayMode.allCases) != nil else { return }
        settingsTab = .display
        shell.open(.settings)
    }

    /// Supply the shell's monitor lifetime, rather than the transport's reusable camera ID.
    public func synchronize(source: UUID?) {
        guard source != self.source else { return }
        retire()
        self.source = source
        guard let source else { return }
        interactive = false
        let capturedRevision = revision
        let sleep = sleep
        armTask = Task { @MainActor [weak self] in
            await sleep(.milliseconds(550))
            guard !Task.isCancelled, let self,
                self.source == source, self.revision == capturedRevision else { return }
            self.interactive = true
            self.armTask = nil
        }
    }

    public func close() {
        retire()
        source = nil
    }

    private func retire() {
        revision &+= 1
        armTask?.cancel(); armTask = nil
        interactive = true
        displaySession.retireEditor()
    }
}
