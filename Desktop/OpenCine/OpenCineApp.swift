import AppKit
import OpenCineDesktopKit
import SwiftUI

/// OpenCine has no window of its own while a camera module runs: the selected module's window is
/// the window, with the tabs in its title bar. The dock keeps the module processes, the driver and
/// the tabs, and shows a small window of its own only while no module can show them.
@main
@MainActor
final class OpenCineApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = DockModel()
    private var fallbackWindow: NSWindow?
    /// True while a module's close button is being answered, so the dock's alert stays in front.
    private var closing = false

    static func main() {
        let app = NSApplication.shared
        let delegate = OpenCineApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0.processIdentifier != getpid() }
        if let first = others.first {
            first.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = Self.makeMainMenu()
        model.onWindowStateChange = { [weak self] in self?.updateFallbackWindow() }
        model.onCloseRequested = { [weak self] in
            guard let self, !self.closing else { return }
            // The live-input confirmation is the dock's alert, so the dock comes forward first.
            self.closing = true
            NSApp.activate()
            NSApp.terminate(nil)
            // Still here: the owner kept the cameras running.
            self.closing = false
            self.model.bringForward()
        }
        NSApp.activate()
        model.load()
    }

    /// Shows the dock's own window only while no module can show the tabs.
    private func updateFallbackWindow() {
        if model.needsFallbackWindow {
            let window = fallbackWindow ?? makeFallbackWindow()
            fallbackWindow = window
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        } else if let window = fallbackWindow, window.isVisible {
            window.orderOut(nil)
        }
    }

    private func makeFallbackWindow() -> NSWindow {
        let size = NSSize(width: 720, height: 120)
        let frame = model.coordinator.frame
        let window = NSWindow(
            contentRect: NSRect(
                x: frame.x + (frame.width - size.width) / 2, y: frame.y + frame.height - size.height,
                width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "OpenCine"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: TabStrip(model: model))
        host.sizingOptions = []
        window.contentView = host
        return window
    }

    private static func makeMainMenu() -> NSMenu {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide OpenCine", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenCine", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        return menu
    }

    /// Quitting ends every input, so it asks while any camera is live, as the close button does.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.anyLive else { return .terminateNow }
        return confirmStoppingLiveInputs() ? .terminateNow : .terminateCancel
    }

    private func confirmStoppingLiveInputs() -> Bool {
        let alert = NSAlert()
        alert.messageText = "A camera is live"
        alert.informativeText =
            "Quitting OpenCine stops every camera input, so apps using them will show nothing."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// The Dock icon brings the selected camera's window forward (or the dock's own window).
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if model.needsFallbackWindow {
            updateFallbackWindow()
            if fallbackWindow?.isMiniaturized == true { fallbackWindow?.deminiaturize(nil) }
            fallbackWindow?.makeKeyAndOrderFront(nil)
        } else {
            model.bringForward()
        }
        return false
    }

    /// Switching to OpenCine (the modules have no entry of their own in the app switcher) brings
    /// the selected camera's window forward.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !closing, !model.needsFallbackWindow else { return }
        model.bringForward()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // `terminate` runs the one live-input confirmation.
        NSApp.terminate(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quitAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
