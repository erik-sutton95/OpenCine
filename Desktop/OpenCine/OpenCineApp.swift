import AppKit
import OpenCineDesktopKit
import SwiftUI

/// OpenCine's window is the tab strip. The selected module's own window sits exactly below it, and
/// moves and resizes with it, so together they read as one window with tabs.
@main
@MainActor
final class OpenCineApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let stripHeight: CGFloat = 44
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
        window.isMovableByWindowBackground = true
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
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        model.load()
    }

    /// The rectangle directly below the strip, in screen coordinates with the origin at the bottom left.
    private func moduleFrame() -> WindowFrame? {
        guard let window else { return nil }
        let strip = window.frame
        return WindowFrame(
            x: strip.minX, y: strip.minY - contentSize.height,
            width: strip.width, height: contentSize.height)
    }

    func windowDidMove(_ notification: Notification) { model.applySelection() }

    func windowDidBecomeKey(_ notification: Notification) { model.applySelection() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.anyLive else {
            NSApp.terminate(nil)
            return false
        }
        let alert = NSAlert()
        alert.messageText = "A camera is live"
        alert.informativeText =
            "Closing OpenCine stops every camera input, so apps using them will show nothing."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Close Anyway")
        if alert.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quitAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
