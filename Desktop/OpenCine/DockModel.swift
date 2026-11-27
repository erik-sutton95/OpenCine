import AppKit
import Foundation
import Observation
import OpenCineDesktopKit
import os

/// The dock's state: installed modules, the driver, the tabs and which module window is on screen.
/// The selected module's window is OpenCine's window; it carries the tabs in its title bar.
@MainActor @Observable
final class DockModel {
    static let modulesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OpenCine/Modules", isDirectory: true)
    static let slotTableURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/OpenCine/virtual-camera-slots.json", isDirectory: false)
    static let dockVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// The tab the owner last chose, kept across launches.
    private static let selectedKey = "selectedModuleID"
    /// The window frame the owner last left, kept across launches.
    private static let frameKey = "windowFrame"
    private static let defaultWidth = 1280.0
    private static let defaultHeight = 800.0
    /// How long a tab switch waits for the new window before the old one goes anyway.
    private static let switchTimeout: Duration = .milliseconds(150)
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenCine", category: "tabs")

    let driver = DriverController()
    private(set) var modules: [ModuleProcess] = []
    private(set) var problem: String?
    private(set) var coordinator = DockWindowCoordinator(selectedID: nil, frame: DockModel.savedFrame())
    /// When each pending `show` was sent, for the switch time in the log.
    @ObservationIgnored private var showSent: [String: (at: ContinuousClock.Instant, token: UUID)] = [:]
    /// When the owner clicked each tab not yet on screen, for the switch time in the log.
    @ObservationIgnored private var switchRequested: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var quitting = false
    /// Which module owns which driver slot, as handed to the driver.
    @ObservationIgnored private var slotTable = VirtualCameraSlotTable()
    /// The selection last handed to the driver, which "OpenCine" shows.
    @ObservationIgnored private var followedSelection: VirtualCameraSelection?
    @ObservationIgnored private var startCheckPending = false
    /// How long a launching module counts as on its way before the dock shows its own window.
    private static let startGrace: Duration = .seconds(10)
    /// Called after anything that can change whether the dock's own window is needed.
    @ObservationIgnored var onWindowStateChange: () -> Void = {}
    /// A module's close button: the dock quits, asking first while an input is live.
    @ObservationIgnored var onCloseRequested: () -> Void = {}

    var selectedID: String? { coordinator.selectedID }

    /// True while no module can show the tabs: none installed, or none running and none that
    /// started in the last 10 seconds (a module that never reports ready does not hide the dock).
    var needsFallbackWindow: Bool {
        guard !quitting else { return false }
        if modules.isEmpty { return true }
        return coordinator.needsFallbackWindow && !modules.contains(where: isStartingInGrace)
    }

    private func isStartingInGrace(_ module: ModuleProcess) -> Bool {
        guard module.phase == .starting, let startedAt = module.startedAt else { return false }
        return ContinuousClock.now - startedAt < Self.startGrace
    }

    /// Tells the app the window state may have changed, and looks again when a starting module's
    /// grace runs out.
    private func windowStateChanged() {
        onWindowStateChange()
        guard !startCheckPending, modules.contains(where: isStartingInGrace) else { return }
        startCheckPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startGrace + .milliseconds(100))
            guard let self else { return }
            self.startCheckPending = false
            self.windowStateChanged()
        }
    }

    func load() {
        let registry = ModuleRegistry(modulesDirectory: Self.modulesDirectory, dockVersion: Self.dockVersion)
        let installed = registry.installed()
        var table: VirtualCameraSlotTable
        do {
            table = try VirtualCameraSlotTableFile.load(from: Self.slotTableURL)
        } catch {
            // Never rewrite a table we could not read: saved scenes depend on its assignments.
            problem = "The camera input table could not be read. Inputs are unavailable until it is repaired."
            windowStateChanged()
            return
        }
        var processes: [ModuleProcess] = []
        for module in installed where module.compatible {
            guard let slot = table.assign(
                moduleID: module.manifest.id, displayName: module.manifest.inputName)
            else {
                problem = "No free camera input for \(module.manifest.displayName)."
                continue
            }
            processes.append(ModuleProcess(module: module, slot: slot))
        }
        do {
            try FileManager.default.createDirectory(
                at: Self.slotTableURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try VirtualCameraSlotTableFile.save(table, to: Self.slotTableURL)
        } catch {
            problem = "The camera input table could not be saved: \(error.localizedDescription)"
        }
        modules = processes
        slotTable = table
        let remembered = UserDefaults.standard.string(forKey: Self.selectedKey)
        coordinator = DockWindowCoordinator(
            selectedID: modules.first { $0.id == remembered }?.id ?? modules.first?.id,
            frame: Self.savedFrame())
        for module in modules {
            module.onEvent = { [weak self] module, message in self?.handle(message, from: module) }
        }
        driver.onDriverArrived = { [weak self] in
            for module in self?.modules ?? [] { module.restartRunning() }
        }
        driver.ensureInstalled()
        observeDriver()
        DriverChannel.keepDelivered(table)
        followSelection()
        for module in modules { module.start() }
        windowStateChanged()
    }

    /// Hands the driver the selected tab's slot whenever the selection changes, so the "OpenCine"
    /// input shows that tab's camera.
    private func followSelection() {
        let selection = VirtualCameraSelection(
            selectedModuleID: coordinator.selectedID, table: slotTable)
        guard selection != followedSelection else { return }
        followedSelection = selection
        DriverChannel.follow(selection)
    }

    /// The owner chose a tab, in a module's tab bar or the dock's own window. A stopped module is
    /// started again and comes in front once it is ready.
    func select(_ id: String) {
        guard let module = modules.first(where: { $0.id == id }) else { return }
        if module.phase == .crashed || module.phase == .stopped { module.start() }
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
        let commands = coordinator.select(id)
        followSelection()
        // The tabs first, so no window comes in with the old selection drawn.
        refreshTabs()
        perform(commands)
        windowStateChanged()
    }

    /// The owner asked for OpenCine, such as by clicking its Dock icon.
    func bringForward() {
        perform(coordinator.bringForward())
    }

    var anyLive: Bool {
        modules.contains { if case .live = $0.status { true } else { false } }
    }

    /// Ends every module before the dock exits, since nothing is left to escalate afterwards.
    func quitAll() {
        quitting = true
        for module in modules { module.quit() }
        let deadline = Date().addingTimeInterval(2)
        while modules.contains(where: \.isProcessRunning), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        for module in modules { module.forceStop() }
    }

    private func handle(_ message: ModuleMessage?, from module: ModuleProcess) {
        guard !quitting else { return }
        switch message {
        case .ready:
            // The tabs first, so the bar is filled before the window comes in.
            refreshTabs()
            perform(coordinator.moduleReady(module.id))
        case .status:
            refreshTabs()
        case .selectTab(let id):
            if id != coordinator.selectedID { switchRequested[id] = .now }
            select(id)
        case .windowFrame(let frame, let final):
            perform(coordinator.windowMoved(by: module.id, to: frame))
            // Saved only when the coordinator took it, from the window on screen.
            if final, coordinator.frame == frame { Self.save(frame) }
        case .shown:
            let sent = showSent.removeValue(forKey: module.id)
            if let clicked = switchRequested.removeValue(forKey: module.id) {
                Self.log.info(
                    "Tab \(module.id, privacy: .public) on screen \(Self.milliseconds(since: clicked)) ms after the click")
            } else if let sent {
                Self.log.info(
                    "Tab \(module.id, privacy: .public) on screen \(Self.milliseconds(since: sent.at)) ms after show")
            }
            perform(coordinator.moduleShown(module.id))
        case .closeRequested:
            onCloseRequested()
        case nil:
            showSent[module.id] = nil
            switchRequested[module.id] = nil
            let commands = coordinator.moduleStopped(module.id)
            refreshTabs()
            perform(commands)
        }
        // A module that becomes ready or stops can move the selection.
        followSelection()
        windowStateChanged()
    }

    /// Sends the coordinator's instructions. A `show` starts the switch timeout; while the dock is
    /// the active app (its own window, its Dock icon) the shown module is activated from here,
    /// since an accessory app cannot always take focus by itself.
    private func perform(_ commands: [DockWindowCoordinator.Command]) {
        for command in commands {
            guard let module = modules.first(where: { $0.id == command.moduleID }) else { continue }
            module.send(command.message)
            guard case .show = command.message else { continue }
            if NSApp.isActive { module.activate() }
            let id = command.moduleID
            let token = UUID()
            showSent[id] = (.now, token)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.switchTimeout)
                // Only this show's timeout: a later show to the same module has its own.
                guard let self, self.showSent[id]?.token == token else { return }
                self.showSent[id] = nil
                Self.log.info("Tab \(id, privacy: .public) did not confirm in time; switching anyway")
                self.perform(self.coordinator.switchTimedOut(id))
            }
        }
    }

    /// Sends the tabs, their states, the selection and the driver notice to every running module.
    private func refreshTabs() {
        let tabs = modules.map {
            DockTab(
                id: $0.id, displayName: $0.module.manifest.displayName, state: Self.tabState(of: $0),
                bundleID: $0.bundleID)
        }
        let message = DockMessage.tabs(tabs, selectedID: coordinator.selectedID, notice: notice)
        for module in modules where module.phase == .running { module.send(message) }
    }

    /// The driver state lives in its own observable; a change reaches the tab bars from here.
    private func observeDriver() {
        withObservationTracking {
            _ = driver.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshTabs()
                self?.observeDriver()
            }
        }
    }

    static func tabState(of module: ModuleProcess) -> DockTab.State {
        switch module.phase {
        case .stopped, .crashed: return .stopped
        case .starting: return .connecting
        case .running:
            switch module.status {
            case .idle: return .idle
            case .connecting: return .connecting
            case .live: return .live
            case .failed: return .failed
            }
        }
    }

    /// The line at the trailing end of the tab bar, if any.
    var notice: DockNotice? {
        if problem == nil, driver.state == .awaitingApproval {
            return DockNotice(text: "Turn on camera driver", opensDriverSettings: true)
        }
        let text = noticeText
        return text.isEmpty ? nil : DockNotice(text: text, opensDriverSettings: false)
    }

    var noticeText: String {
        if let problem { return problem }
        switch driver.state {
        case .checking: return "Checking camera driver"
        case .notInstalled: return "Installing camera driver"
        case .awaitingApproval, .installed: return ""
        case .restartNeeded: return "Restart the Mac to finish the camera driver"
        case .failed(let reason): return "Camera driver: \(reason)"
        }
    }

    /// The saved frame, moved to a current screen when its display is gone. The first launch gets a
    /// centred default (an empty frame overlaps no screen).
    private static func savedFrame() -> WindowFrame {
        let screens = NSScreen.screens.map {
            WindowFrame(
                x: $0.visibleFrame.minX, y: $0.visibleFrame.minY,
                width: $0.visibleFrame.width, height: $0.visibleFrame.height)
        }
        let saved = UserDefaults.standard.data(forKey: frameKey)
            .flatMap { try? JSONDecoder().decode(WindowFrame.self, from: $0) }
        let fallback = WindowFrame(x: 0, y: 0, width: 0, height: 0)
        return (saved ?? fallback).fitted(
            onto: screens, defaultWidth: defaultWidth, defaultHeight: defaultHeight)
    }

    private static func save(_ frame: WindowFrame) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        UserDefaults.standard.set(data, forKey: frameKey)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}
