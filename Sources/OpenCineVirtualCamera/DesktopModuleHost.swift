#if targetEnvironment(macCatalyst)
    import CoreImage
    import Foundation
    import ObjectiveC
    import OpenCineDesktopKit
    import os
    import UIKit

    /// What runs a Catalyst app as a camera module of the OpenCine dock: its slot's webcam output,
    /// the channel to the dock on standard input, and its window, which carries the dock's tabs in its
    /// title bar and is shown, placed and hidden as the dock says.
    /// `nil` when the app was not started by the dock, so a direct launch behaves as before.
    @available(macCatalyst 17.0, *)
    @MainActor
    public final class DesktopModuleHost {
        public static let current: DesktopModuleHost? = launchedByDock(
            environment: ProcessInfo.processInfo.environment)

        public let moduleID: String
        public let slot: VirtualCameraSlot
        public let output: VirtualCameraOutput
        /// What the window's toolbar buttons and keys run: the app's monitor registers its actions.
        public let commands = DesktopCommands()
        private var inbound = Data()
        private var lastStatus: ModuleStatus?
        private nonisolated let lastFrame = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        private var started = false
        private var statusTimer: Timer?
        private var windowTimer: Timer?
        /// The dock's latest visibility instruction, `show` or `hide`. Kept as instructed by the hold
        /// timer, since the first one can arrive before the window exists.
        private var windowInstruction: DockMessage?
        /// The latest frame the dock asked for. A newly created window opens there, and a hidden
        /// window is kept there; a visible window is never moved by the timer, so it cannot fight a drag.
        private var instructedFrame: WindowFrame?
        /// Windows already placed once, so later timer ticks leave them where the owner puts them.
        private var placedWindows: Set<ObjectIdentifier> = []
        /// Waiting for the window to be on screen before answering `shown`.
        private var awaitingShown = false
        private let tabBar = DesktopTabBarModel()
        private lazy var toolbar = DesktopTabToolbar(model: tabBar, commands: commands)
        private lazy var closeTarget = DesktopCloseTarget { [weak self] in self?.closeRequested() }
        /// The dock's bundle identifier, so this module can hand it keyboard focus for its alert.
        private let dockBundleID: String?
        /// Frame reports: at most one per 100 ms while the window moves, and a final one once it settles.
        private var lastFrameReport: (frame: WindowFrame, at: UInt64)?
        private var finalFrameTimer: Timer?
        private var windowObservers: [NSObjectProtocol] = []

        static func launchedByDock(environment: [String: String]) -> DesktopModuleHost? {
            guard let moduleID = environment["OPENCINE_MODULE_ID"],
                let number = environment["OPENCINE_MODULE_SLOT"].flatMap(Int.init),
                let slot = VirtualCameraSlot(number: number)
            else { return nil }
            return DesktopModuleHost(
                moduleID: moduleID, slot: slot, dockBundleID: environment["OPENCINE_DOCK_BUNDLE_ID"])
        }

        private init(moduleID: String, slot: VirtualCameraSlot, dockBundleID: String?) {
            self.moduleID = moduleID
            self.slot = slot
            self.dockBundleID = dockBundleID
            output = VirtualCameraOutput(slot: slot)
        }

        /// Call once at launch. Webcam output is on by default in a module.
        public func start() {
            guard !started else { return }
            started = true
            AppKitBridge.setAccessoryActivationPolicy()
            output.setEnabled(true)
            tabBar.onSelect = { [weak self] id in self?.selectTab(id) }
            toolbar.installOnConnectedScenes()
            observeWindowFrames()
            startReadingChannel()
            send(.ready(moduleID: moduleID))
            report(.idle)
            windowTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdWindow() }
            }
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatus() }
            }
        }

        /// Records that a real picture reached the output. Cheap enough to call per frame.
        public nonisolated func noteFrame() {
            let now = DispatchTime.now().uptimeNanoseconds
            lastFrame.withLock { $0 = now }
        }

        /// Sends one clean picture to this module's input.
        public nonisolated func publish(_ image: CIImage) {
            noteFrame()
            output.submit(image)
        }

        /// A camera counts as live while pictures arrive, whichever route they take.
        private func updateStatus() {
            let last = lastFrame.withLock { $0 }
            let now = DispatchTime.now().uptimeNanoseconds
            let live = last.map { now - $0 < 2_000_000_000 } ?? false
            report(live ? .live(cameraName: nil) : .idle)
        }

        public func report(_ status: ModuleStatus) {
            guard status != lastStatus else { return }
            lastStatus = status
            send(.status(status))
        }

        private func received(_ data: Data) {
            inbound.append(data)
            guard let messages: [DockMessage] = try? LengthPrefixedJSON.decodeAll(&inbound) else {
                inbound = Data()
                return
            }
            for message in messages {
                switch message {
                case .show(let frame):
                    windowInstruction = message
                    instructedFrame = frame
                    // The window is moved by this instruction, not by the owner: no report for it.
                    lastFrameReport = (frame, DispatchTime.now().uptimeNanoseconds)
                    awaitingShown = true
                    toolbar.installOnConnectedScenes()
                    AppKitBridge.show(at: frame, closeTarget: closeTarget)
                    confirmShownIfVisible()
                case .place(let frame):
                    instructedFrame = frame
                    AppKitBridge.place(at: frame)
                case .hide:
                    windowInstruction = message
                    awaitingShown = false
                    finalFrameTimer?.invalidate()
                    // A minimized window goes too, so its Dock tile cannot bring back a hidden tab.
                    AppKitBridge.hideAll(includingMinimized: true)
                case .tabs(let tabs, let selectedID, let notice):
                    tabBar.tabs = tabs
                    tabBar.selectedID = selectedID
                    tabBar.notice = notice
                case .quit: exit(0)
                }
            }
        }

        private var isShownTab: Bool {
            if case .show = windowInstruction { true } else { false }
        }

        /// Keeps visibility as instructed and places windows the first time they are seen. A visible
        /// window keeps whatever frame the owner gives it.
        private func holdWindow() {
            toolbar.installOnConnectedScenes()
            DesktopKeyInstaller.install()
            let windows = AppKitBridge.windows
            // Forget windows that are gone, so a new one with a reused address is placed too.
            placedWindows.formIntersection(windows.map(ObjectIdentifier.init))
            for window in windows {
                AppKitBridge.prepare(window, closeTarget: closeTarget)
                let fresh = placedWindows.insert(ObjectIdentifier(window)).inserted
                if fresh || !isShownTab, let instructedFrame {
                    AppKitBridge.setFrame(instructedFrame, of: window)
                }
            }
            // Until the dock says otherwise the window stays out of sight, so a module the dock has
            // just launched does not flash at the frame the system restored.
            if isShownTab {
                AppKitBridge.keepShown()
            } else {
                AppKitBridge.hideAll(includingMinimized: false)
            }
            confirmShownIfVisible()
        }

        /// Answers `shown` once the window is on screen and has drawn: the next main run loop turn,
        /// after this turn's drawing has been committed. Only then may the dock hide the old window.
        private func confirmShownIfVisible() {
            guard awaitingShown, isShownTab, AppKitBridge.anyWindowVisible else { return }
            awaitingShown = false
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isShownTab else { return }
                    self.send(.shown)
                }
            }
        }

        private func selectTab(_ id: String) {
            // A click right after a drag: the dock gets the settled frame before it switches.
            if finalFrameTimer?.isValid == true { reportFrame(final: true) }
            // macOS lets the next module take keyboard focus only when this one, the active app,
            // yields it.
            if id != tabBar.selectedID, let bundleID = tabBar.tabs.first(where: { $0.id == id })?.bundleID {
                AppKitBridge.yieldActivation(toBundleID: bundleID)
            }
            send(.selectTab(id: id))
        }

        /// A key from the window's key table. Tab keys switch tabs through the dock, as a click does.
        func perform(_ shortcut: DesktopShortcut) {
            let ids = tabBar.tabs.map(\.id)
            let selected = tabBar.selectedID.flatMap { ids.firstIndex(of: $0) }
            if let index = DesktopKeyCommands.tabIndex(for: shortcut, selected: selected, tabCount: ids.count) {
                if ids[index] != tabBar.selectedID { selectTab(ids[index]) }
                return
            }
            commands.perform(shortcut)
        }

        var tabCount: Int { tabBar.tabs.count }

        /// The dock asks before quitting while an input is live, so it gets keyboard focus first.
        private func closeRequested() {
            if let dockBundleID { AppKitBridge.yieldActivation(toBundleID: dockBundleID) }
            send(.closeRequested)
        }

        private func observeWindowFrames() {
            for name in ["NSWindowDidMoveNotification", "NSWindowDidResizeNotification"] {
                windowObservers.append(
                    NotificationCenter.default.addObserver(
                        forName: Notification.Name(name), object: nil, queue: .main
                    ) { [weak self] notification in
                        let isContent = (notification.object as? NSObject).map(AppKitBridge.isContentWindow)
                        MainActor.assumeIsolated {
                            guard isContent == true else { return }
                            self?.windowFrameChanged()
                        }
                    })
            }
        }

        private func windowFrameChanged() {
            guard isShownTab, let frame = AppKitBridge.visibleFrame, frame != lastFrameReport?.frame
            else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if let last = lastFrameReport, now - last.at < 100_000_000 {
                // Too soon for another; the final report carries it.
            } else {
                reportFrame(final: false)
            }
            finalFrameTimer?.invalidate()
            let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportFrame(final: true) }
            }
            RunLoop.main.add(timer, forMode: .common)
            finalFrameTimer = timer
        }

        private func reportFrame(final: Bool) {
            if final { finalFrameTimer?.invalidate() }
            guard isShownTab, let frame = AppKitBridge.visibleFrame else { return }
            lastFrameReport = (frame, DispatchTime.now().uptimeNanoseconds)
            // The dock's latest frame for this window is now this one.
            instructedFrame = frame
            send(.windowFrame(frame, final: final))
        }

        /// The channel is a socket on standard input. A plain blocking reader stays reliable where a
        /// `FileHandle` readability handler stopped after its first message, because each `send`
        /// made and released another `FileHandle` for the same descriptor.
        private func startReadingChannel() {
            let thread = Thread { [weak self] in
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while true {
                    let count = read(0, &buffer, buffer.count)
                    if count < 0, errno == EINTR { continue }
                    // The dock going away must not take a live camera with it.
                    guard count > 0 else { return }
                    let data = Data(buffer[0..<count])
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.received(data) }
                    }
                }
            }
            thread.name = "com.opencapture.opencine.module-channel"
            thread.start()
        }

        private func send(_ message: ModuleMessage) {
            guard let data = try? LengthPrefixedJSON.encode(message) else { return }
            var noSignal: Int32 = 1
            setsockopt(0, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(0, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { return }
                    offset += written
                }
            }
        }
    }

    /// Puts the key table (`DesktopKeyCommands`) on each scene window's root view controller. The
    /// commands' action is a method on `UIWindow`, which is in every responder chain of the window.
    @available(macCatalyst 17.0, *)
    @MainActor
    enum DesktopKeyInstaller {
        static let action = #selector(UIWindow.openCineDesktopKey(_:))
        /// Roots already given the table, so the timer never adds it twice even where a root does
        /// not list added commands in `keyCommands`.
        private static let installed = NSHashTable<UIViewController>.weakObjects()

        static func install() {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for window in scenes.flatMap(\.windows) {
                guard let root = window.rootViewController, !installed.contains(root),
                    !(root.keyCommands ?? []).contains(where: { $0.action == action })
                else { continue }
                installed.add(root)
                for key in DesktopKeyCommands.registered {
                    let command = UIKeyCommand(
                        input: key.input, modifierFlags: flags(key.modifiers), action: action)
                    // ⌘, and the tab keys would otherwise go to the system first.
                    command.wantsPriorityOverSystemBehavior = true
                    root.addKeyCommand(command)
                }
            }
        }

        static func flags(_ modifiers: DesktopModifiers) -> UIKeyModifierFlags {
            var flags: UIKeyModifierFlags = []
            if modifiers.contains(.command) { flags.insert(.command) }
            if modifiers.contains(.shift) { flags.insert(.shift) }
            if modifiers.contains(.control) { flags.insert(.control) }
            if modifiers.contains(.option) { flags.insert(.alternate) }
            return flags
        }

        static func modifiers(_ flags: UIKeyModifierFlags) -> DesktopModifiers {
            var modifiers: DesktopModifiers = []
            if flags.contains(.command) { modifiers.insert(.command) }
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.alternate) { modifiers.insert(.option) }
            return modifiers
        }

        /// The responder that has focus, found by sending an action to the first responder.
        private static weak var focused: UIResponder?

        static func focusedResponder() -> UIResponder? {
            focused = nil
            UIApplication.shared.sendAction(#selector(UIResponder.openCineDesktopReportFocus(_:)), to: nil, from: nil, for: nil)
            return focused
        }

        static func noteFocused(_ responder: UIResponder) { focused = responder }
    }

    @available(macCatalyst 17.0, *)
    extension UIResponder {
        @objc func openCineDesktopReportFocus(_ sender: Any?) {
            MainActor.assumeIsolated { DesktopKeyInstaller.noteFocused(self) }
        }
    }

    @available(macCatalyst 17.0, *)
    extension UIWindow {
        /// Runs a key of the module window's key table. A plain key pressed while text has focus
        /// types its letter into that text instead.
        @objc func openCineDesktopKey(_ sender: UIKeyCommand) {
            MainActor.assumeIsolated {
                guard let input = sender.input, let host = DesktopModuleHost.current else { return }
                let focused = DesktopKeyInstaller.focusedResponder()
                let textHasFocus = focused is UITextInput
                let modifiers = DesktopKeyInstaller.modifiers(sender.modifierFlags)
                if let shortcut = DesktopKeyCommands.action(
                    input: input, modifiers: modifiers, textHasFocus: textHasFocus, tabCount: host.tabCount)
                {
                    host.perform(shortcut)
                } else if modifiers.isEmpty, let text = focused as? UIKeyInput {
                    text.insertText(input)
                }
            }
        }
    }

    /// Receives the window's close button: the dock decides, the module never closes its own window.
    @MainActor
    final class DesktopCloseTarget: NSObject {
        private let action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func closeRequested(_ sender: Any?) { action() }
    }

    /// AppKit calls Catalyst has no public route to, by name. Each call checks the selector exists,
    /// so a system change costs window placement rather than the camera feed.
    @MainActor
    enum AppKitBridge {
        private static var application: NSObject? {
            (NSClassFromString("NSApplication") as? NSObject.Type)?
                .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        }

        static var windows: [NSObject] {
            let all =
                application?.perform(NSSelectorFromString("windows"))?.takeUnretainedValue() as? [NSObject]
                ?? []
            return all.filter(isContentWindow)
        }

        /// A window the module shows its camera in: a UIKit scene's own window. Every other window
        /// keeps its own style, place and size: file panels, alerts, and the system's helper windows
        /// such as the text input window, which turned into a stray set of window buttons when it was
        /// given a title bar.
        nonisolated static func isContentWindow(_ window: NSObject) -> Bool {
            guard window.responds(to: NSSelectorFromString("setFrame:display:")) else { return false }
            if let sceneWindow = NSClassFromString("UINSWindow") {
                return window.isKind(of: sceneWindow)
            }
            // Without that class, only windows the system made titled are scene windows.
            let titled = 1
            return (window.value(forKey: "styleMask") as? Int).map { $0 & titled != 0 } ?? false
        }

        static func setAccessoryActivationPolicy() {
            guard let application else { return }
            let selector = NSSelectorFromString("setActivationPolicy:")
            guard application.responds(to: selector) else { return }
            typealias Function = @convention(c) (AnyObject, Selector, Int) -> Bool
            // NSApplicationActivationPolicyAccessory: no Dock icon, windows still work.
            _ = unsafeBitCast(application.method(for: selector), to: Function.self)(
                application, selector, 1)
        }

        private static func isVisible(_ window: NSObject) -> Bool {
            window.value(forKey: "visible") as? Bool ?? false
        }

        private static func isMiniaturized(_ window: NSObject) -> Bool {
            window.value(forKey: "miniaturized") as? Bool ?? false
        }

        private static func frame(of window: NSObject) -> WindowFrame? {
            guard let rect = (window.value(forKey: "frame") as? NSValue)?.cgRectValue else { return nil }
            return WindowFrame(
                x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
        }

        static var anyWindowVisible: Bool { windows.contains(where: isVisible) }

        /// The frame of the window on screen, in AppKit screen coordinates.
        static var visibleFrame: WindowFrame? {
            windows.first(where: isVisible).flatMap(frame(of:))
        }

        /// Sets the window's frame when it differs, without ordering it in.
        static func setFrame(_ frame: WindowFrame, of window: NSObject) {
            guard self.frame(of: window) != frame else { return }
            let selector = NSSelectorFromString("setFrame:display:")
            guard window.responds(to: selector) else { return }
            let target = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            typealias Function = @convention(c) (AnyObject, Selector, CGRect, Bool) -> Void
            unsafeBitCast(window.method(for: selector), to: Function.self)(window, selector, target, true)
        }

        /// The dock chose this tab: the window comes in front at `frame`, restored if minimized, and
        /// the module takes keyboard focus.
        static func show(at frame: WindowFrame, closeTarget: DesktopCloseTarget) {
            for window in windows {
                prepare(window, closeTarget: closeTarget)
                setFrame(frame, of: window)
                if isMiniaturized(window) {
                    window.perform(NSSelectorFromString("deminiaturize:"), with: nil)
                }
                window.perform(NSSelectorFromString("makeKeyAndOrderFront:"), with: nil)
                window.perform(NSSelectorFromString("orderFrontRegardless"))
            }
            activate()
        }

        /// A hidden window follows the visible one's frame, out of sight.
        static func place(at frame: WindowFrame) {
            for window in windows { setFrame(frame, of: window) }
        }

        /// Brings back a window that is neither on screen nor minimized by the owner, such as one
        /// created after the instruction arrived.
        static func keepShown() {
            for window in windows where !isVisible(window) && !isMiniaturized(window) {
                window.perform(NSSelectorFromString("orderFrontRegardless"))
            }
        }

        static func hideAll(includingMinimized: Bool) {
            for window in windows where isVisible(window) || (includingMinimized && isMiniaturized(window)) {
                window.perform(NSSelectorFromString("orderOut:"), with: nil)
            }
        }

        /// Lets another app take keyboard focus from this one (macOS 14 and later).
        static func yieldActivation(toBundleID bundleID: String) {
            guard let application else { return }
            let selector = NSSelectorFromString("yieldActivationToApplicationWithBundleIdentifier:")
            guard application.responds(to: selector) else { return }
            application.perform(selector, with: bundleID as NSString)
        }

        private static func activate() {
            guard let application else { return }
            let modern = NSSelectorFromString("activate")
            if application.responds(to: modern) {
                application.perform(modern)
                return
            }
            let legacy = NSSelectorFromString("activateIgnoringOtherApps:")
            guard application.responds(to: legacy) else { return }
            typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(application.method(for: legacy), to: Function.self)(application, legacy, true)
        }

        /// A normal Mac window: title bar (holding the tabs), close, minimize and resize, movable,
        /// no full screen. The close button asks the dock instead of closing the window.
        static func prepare(_ window: NSObject, closeTarget: DesktopCloseTarget) {
            let titled = 1
            let closable = 1 << 1
            let miniaturizable = 1 << 2
            let resizable = 1 << 3
            let wanted = titled | closable | miniaturizable | resizable
            typealias SetInteger = @convention(c) (AnyObject, Selector, Int) -> Void
            let mask = NSSelectorFromString("setStyleMask:")
            if let current = window.value(forKey: "styleMask") as? Int, current & wanted != wanted,
                window.responds(to: mask)
            {
                unsafeBitCast(window.method(for: mask), to: SetInteger.self)(window, mask, current | wanted)
            }
            let movable = NSSelectorFromString("setMovable:")
            if (window.value(forKey: "movable") as? Bool) == false, window.responds(to: movable) {
                typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(window.method(for: movable), to: SetFlag.self)(window, movable, true)
            }
            // NSWindowCollectionBehaviorFullScreenPrimary and FullScreenNone.
            let fullScreenPrimary = 1 << 7
            let fullScreenNone = 1 << 9
            let behavior = NSSelectorFromString("setCollectionBehavior:")
            if let current = window.value(forKey: "collectionBehavior") as? Int,
                current & fullScreenNone == 0 || current & fullScreenPrimary != 0,
                window.responds(to: behavior)
            {
                unsafeBitCast(window.method(for: behavior), to: SetInteger.self)(
                    window, behavior, (current & ~fullScreenPrimary) | fullScreenNone)
            }
            retargetCloseButton(of: window, to: closeTarget)
        }

        private static func retargetCloseButton(of window: NSObject, to closeTarget: DesktopCloseTarget) {
            typealias Button = @convention(c) (AnyObject, Selector, Int) -> AnyObject?
            let buttonSelector = NSSelectorFromString("standardWindowButton:")
            guard window.responds(to: buttonSelector),
                let button = unsafeBitCast(window.method(for: buttonSelector), to: Button.self)(
                    window, buttonSelector, 0) as? NSObject
            else { return }
            let setTarget = NSSelectorFromString("setTarget:")
            let setAction = NSSelectorFromString("setAction:")
            guard button.responds(to: setTarget), button.responds(to: setAction) else { return }
            if (button.value(forKey: "target") as AnyObject?) === closeTarget { return }
            button.perform(setTarget, with: closeTarget)
            typealias SetAction = @convention(c) (AnyObject, Selector, Selector) -> Void
            unsafeBitCast(button.method(for: setAction), to: SetAction.self)(
                button, setAction, #selector(DesktopCloseTarget.closeRequested(_:)))
        }
    }
#endif
