import AppKit
import OpenCineDesktopKit
import SwiftUI

/// OpenCine's window is the tab strip. The selected module's own window sits exactly below it, and
/// moves and resizes with it, so together they read as one window with tabs.
@main
@MainActor
final class OpenCineApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let stripHeight: CGFloat = 44
    /// The strip's leading space, which holds the window buttons.
    private static let windowButtonsWidth: CGFloat = 76
    private let model = DockModel()
    private var window: NSWindow!
    private var contentSize = NSSize(width: 1280, height: 756)

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
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: Self.stripHeight),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The dock moves the strip itself: macOS reports a system drag only when it ends, and the
        // module's window has to follow every step.
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The hosting view would otherwise size the window to its own ideal and add the title bar.
        let host = NSHostingView(rootView: TabStrip(model: model))
        host.sizingOptions = []
        window.contentView = host
        // The content view fills the frame, so the strip's own height is the whole window.
        let screen = NSScreen.main?.visibleFrame ?? .zero
        window.setFrame(
            NSRect(
                x: screen.midX - contentSize.width / 2,
                y: screen.midY + contentSize.height / 2 - Self.stripHeight / 2,
                width: contentSize.width, height: Self.stripHeight), display: true)
        model.contentFrame = { [weak self] in self?.moduleFrame() }
        NSApp.mainMenu = Self.makeMainMenu()
        installStripDrag()
        followStrip()
        // A click in a module brings only that process forward, so the strip follows it.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.load()
    }

    /// Keeps the module under the strip however the strip got there: a drag, a display change or
    /// another app. The window delegate's move callback did not arrive for these moves.
    private func followStrip() {
        var last = window.frame
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let frame = self.window?.frame, frame != last else { return }
                last = frame
                self.model.applySelection()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Drags the strip, and the selected module with it, from anywhere but the window buttons.
    private func installStripDrag() {
        var start: (mouse: NSPoint, origin: NSPoint)?
        var dragging = false
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let mouse = NSEvent.mouseLocation
            switch event.type {
            case .leftMouseDown:
                dragging = false
                start = event.locationInWindow.x > Self.windowButtonsWidth
                    ? (mouse, window.frame.origin) : nil
            case .leftMouseDragged:
                guard let start else { return event }
                let delta = NSPoint(x: mouse.x - start.mouse.x, y: mouse.y - start.mouse.y)
                if !dragging, hypot(delta.x, delta.y) < 3 { return event }
                dragging = true
                window.setFrameOrigin(
                    NSPoint(x: start.origin.x + delta.x, y: start.origin.y + delta.y))
                self.model.applySelection()
                return nil
            case .leftMouseUp:
                start = nil
                if dragging {
                    dragging = false
                    return nil
                }
            default: break
            }
            return event
        }
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

    @objc private func applicationActivated(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            model.ownsProcess(app.processIdentifier), window?.isMiniaturized == false
        else { return }
        window?.orderFrontRegardless()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.windowsVisible = false
        model.applySelection()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.windowsVisible = true
        model.applySelection()
    }

    func applicationDidHide(_ notification: Notification) {
        model.windowsVisible = false
        model.applySelection()
    }

    func applicationDidUnhide(_ notification: Notification) {
        model.windowsVisible = true
        model.applySelection()
    }

    /// Quitting ends every input, so it asks while any camera is live, as closing the window does.
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

    /// The rectangle directly below the strip, in screen coordinates with the origin at the bottom left.
    private func moduleFrame() -> WindowFrame? {
        guard let window else { return nil }
        let strip = window.frame
        return WindowFrame(
            x: strip.minX, y: strip.minY - contentSize.height,
            width: strip.width, height: contentSize.height)
    }

    func windowDidBecomeKey(_ notification: Notification) { model.applySelection() }

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
