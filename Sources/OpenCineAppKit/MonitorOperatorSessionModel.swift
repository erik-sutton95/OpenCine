import Foundation
import MonitorPresentation
import Observation
import OpenCineCore

/// The one owner of the monitor's display intent: the DISP modes a source offers and the current
/// one, each mode's chrome, the chrome editor and its return to Settings, the interface lock and
/// the connect-tap arming lifetime. Every app's live surface reads it; none keeps its own copy.
/// The shell retains the camera; this owner closes presentation without sending a command.
///
/// Kotlin mirror: `MonitorOperatorSessionModel` in `:appkit`, same names.
@available(macOS 14, *)
@MainActor @Observable
public final class MonitorOperatorSessionModel<Looks: MonitorLookProvider> {
    public var live: MonitorDisplayChrome { didSet { preferences.live = live } }
    public var clean: MonitorDisplayChrome { didSet { preferences.clean = clean } }
    public var command: MonitorDisplayChrome { didSet { preferences.command = command } }
    /// The one landing-tab rule (A2-84): Settings opens on the tab the operator last chose in this
    /// app run, Link at first, whichever entry opens it (home, the monitor, a cover rehost). Only
    /// the chrome editor's Done picks a tab, Display, the page it returns to.
    public var settingsTab: MonitorSettingsTab = .link
    /// Each settings tab's scroll offset for this app run, so a tab reopens where it was left
    /// (A2-84): after Edit view, a cover rehost or closing Settings.
    public var settingsScrollOffsets: [MonitorSettingsTab: Double] = [:]
    public var editingMode: MonitorDisplayMode? {
        get { displaySession.editingMode }
        set { displaySession.editingMode = newValue }
    }
    public var returnedMode: MonitorDisplayMode? {
        get { displaySession.returnedMode }
        set { displaySession.returnedMode = newValue }
    }
    /// The modes the source offers, in DISP order. Live and Clean unless a source declares more.
    public private(set) var modes: [MonitorDisplayMode] = [.live, .clean]
    /// The interface lock. It refuses the DISP cycle here; the surface refuses every other
    /// operator input while it holds. It lasts one monitor lifetime.
    public var locked = false
    public private(set) var interactive = true

    private let shell: ShellModel
    public let assist: MonitorAssistState<Looks>
    private let preferences: MonitorDisplayPreferences
    private let displaySession = MonitorDisplaySession<MonitorDisplayMode>(mode: .live)
    /// Command has no assist-state twin; Live and Clean stay `assist.clean`, which assist
    /// filtering and saved assist state already follow.
    private var commandShown = false
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    @ObservationIgnored private var source: UUID?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var armTask: Task<Void, Never>?

    public init(shell: ShellModel, assist: MonitorAssistState<Looks>,
        display: MonitorDisplayPreferences,
        sleep: @escaping @MainActor (Duration) async -> Void = hostSleepUntilCancelled(for:)) {
        self.shell = shell; self.assist = assist; preferences = display; self.sleep = sleep
        live = display.live; clean = display.clean; command = display.command
    }

    public var mode: MonitorDisplayMode { commandShown ? .command : assist.clean ? .clean : .live }
    public var chrome: MonitorDisplayChrome { chrome(for: mode) }
    public var isEditing: Bool { editingMode != nil }

    public func chrome(for mode: MonitorDisplayMode) -> MonitorDisplayChrome {
        switch mode {
        case .live: live
        case .clean: clean
        case .command: command
        }
    }

    public func mounts(_ section: MonitorDisplayChrome.Section) -> Bool {
        if editingMode == mode, MonitorDisplayChrome.isConfigurable(section, in: mode) { return true }
        if section == .railSettings {
            return MonitorSideRailPlan.showsSettings(visible: chrome.railSettings,
                reachable: modes.contains(where: { chrome(for: $0).railSettings }))
        }
        return chrome.isVisible(section)
    }

    public func toggle(_ section: MonitorDisplayChrome.Section, in mode: MonitorDisplayMode) {
        guard MonitorDisplayChrome.isConfigurable(section, in: mode) else { return }
        switch mode {
        case .live: live.toggle(section)
        case .clean: clean.toggle(section)
        case .command: command.toggle(section)
        }
    }

    /// The source states which modes it offers. A current mode that leaves the set falls back to
    /// the first, lock or not: the capability went, not the operator's intent.
    public func declare(modes: [MonitorDisplayMode]) {
        guard !modes.isEmpty, modes != self.modes else { return }
        self.modes = modes
        if !modes.contains(mode) { show(modes[0]) }
    }

    /// DISP or a feed swipe. Refused while locked and for a mode the source does not offer.
    @discardableResult public func select(_ next: MonitorDisplayMode) -> Bool {
        guard !locked, next != mode, modes.contains(next) else { return false }
        show(next)
        return true
    }

    /// The DISP key: the next offered mode.
    @discardableResult public func cycle() -> Bool {
        guard let next = MonitorDisplaySession<MonitorDisplayMode>.next(in: modes, after: mode) else {
            return false
        }
        return select(next)
    }

    public func beginEditing(_ mode: MonitorDisplayMode) {
        shell.dismissCover()
        show(mode)
        displaySession.beginEditing(mode)
    }

    public func finishEditing() {
        guard displaySession.finishEditing(order: modes) != nil else { return }
        settingsTab = .display
        shell.open(.settings)
    }

    /// Opens Settings on the operator's last tab and scroll position (the landing-tab rule).
    public func openSettings() { shell.open(.settings) }

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

    private func show(_ next: MonitorDisplayMode) {
        if commandShown != (next == .command) { commandShown = next == .command }
        if assist.clean != (next == .clean) { assist.clean = next == .clean }
    }

    private func retire() {
        revision &+= 1
        armTask?.cancel(); armTask = nil
        interactive = true
        locked = false
        displaySession.retireEditor()
    }
}
