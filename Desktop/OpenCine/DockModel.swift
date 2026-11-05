import AppKit
import Foundation
import Observation
import OpenCineDesktopKit

/// What the dock window shows: installed modules, the driver, the selected tab.
@MainActor @Observable
final class DockModel {
    static let modulesDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OpenCine/Modules", isDirectory: true)
    static let slotTableURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/OpenCine/virtual-camera-slots.json", isDirectory: false)
    static let dockVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    let driver = DriverController()
    private(set) var modules: [ModuleProcess] = []
    private(set) var problem: String?
    var selectedID: String?
    /// The tab the owner last chose, kept across launches.
    private static let selectedKey = "selectedModuleID"
    /// False while the strip is minimized or OpenCine is hidden: every module stays out of sight.
    @ObservationIgnored var windowsVisible = true
    /// The screen rectangle a module's window should fill, in AppKit coordinates.
    @ObservationIgnored var contentFrame: () -> WindowFrame? = { nil }

    func load() {
        let registry = ModuleRegistry(modulesDirectory: Self.modulesDirectory, dockVersion: Self.dockVersion)
        let installed = registry.installed()
        var table: VirtualCameraSlotTable
        do {
            table = try VirtualCameraSlotTableFile.load(from: Self.slotTableURL)
        } catch {
            // Never rewrite a table we could not read: saved scenes depend on its assignments.
            problem = "The camera input table could not be read. Inputs are unavailable until it is repaired."
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
        driver.ensureInstalled()
        DriverSlotTableChannel.keepDelivered(table)
        for module in modules { module.start() }
        let remembered = UserDefaults.standard.string(forKey: Self.selectedKey)
        selectedID = modules.first { $0.id == remembered }?.id ?? modules.first?.id
        applySelection()
    }

    func select(_ id: String) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: Self.selectedKey)
        applySelection()
        modules.first { $0.id == id }?.activate()
    }

    /// Shows the selected module at the content frame and hides the others. Hidden modules keep
    /// feeding their inputs.
    func applySelection() {
        guard let frame = contentFrame() else { return }
        for module in modules {
            module.send(windowsVisible && module.id == selectedID ? .show(frame: frame) : .hide)
        }
    }

    func restart(_ id: String) {
        modules.first { $0.id == id }?.start()
        applySelection()
    }

    var anyLive: Bool {
        modules.contains { if case .live = $0.status { true } else { false } }
    }

    /// Whether this process belongs to one of the modules.
    func ownsProcess(_ identifier: pid_t) -> Bool {
        modules.contains { $0.processIdentifier == identifier }
    }

    func quitAll() {
        for module in modules { module.quit() }
    }
}
