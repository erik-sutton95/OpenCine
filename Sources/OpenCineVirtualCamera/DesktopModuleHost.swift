#if targetEnvironment(macCatalyst)
    import CoreImage
    import Foundation
    import ObjectiveC
    import OpenCineDesktopKit
    import os
    import UIKit

    /// What runs a Catalyst app as a camera module of the OpenCine dock: its slot's webcam output,
    /// the channel to the dock on standard input, and placing its window under the dock's tabs.
    /// `nil` when the app was not started by the dock, so a direct launch behaves as before.
    @available(macCatalyst 17.0, *)
    @MainActor
    public final class DesktopModuleHost {
        public static let current: DesktopModuleHost? = launchedByDock(
            environment: ProcessInfo.processInfo.environment)

        public let moduleID: String
        public let slot: VirtualCameraSlot
        public let output: VirtualCameraOutput
        private var inbound = Data()
        private var lastStatus: ModuleStatus?
        private nonisolated let lastFrame = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        private var statusTimer: Timer?
        private var windowTimer: Timer?
        /// The dock's latest window instruction. Reapplied until it holds: the first one can arrive
        /// before the window exists, and the system can restore a window's old place.
        private var windowInstruction: DockMessage?

        static func launchedByDock(environment: [String: String]) -> DesktopModuleHost? {
            guard let moduleID = environment["OPENCINE_MODULE_ID"],
                let number = environment["OPENCINE_MODULE_SLOT"].flatMap(Int.init),
                let slot = VirtualCameraSlot(number: number)
            else { return nil }
            return DesktopModuleHost(moduleID: moduleID, slot: slot)
        }

        private init(moduleID: String, slot: VirtualCameraSlot) {
            self.moduleID = moduleID
            self.slot = slot
            output = VirtualCameraOutput(slot: slot)
        }

        /// Call once at launch. Webcam output is on by default in a module.
        public func start() {
            AppKitBridge.setAccessoryActivationPolicy()
            output.setEnabled(true)
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
                case .show, .hide:
                    windowInstruction = message
                    holdWindow()
                    // Each instruction is the dock saying this tab is the visible one right now.
                    if case .show = message { AppKitBridge.raise() }
                case .quit: exit(0)
                }
            }
        }

        private func holdWindow() {
            switch windowInstruction {
            case .show(let frame): AppKitBridge.hold(frame: frame)
            case .hide: AppKitBridge.holdHidden()
            case .quit, nil: break
            }
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

    /// AppKit calls Catalyst has no public route to, by name. Each call checks the selector exists,
    /// so a system change costs window placement rather than the camera feed.
    @MainActor
    enum AppKitBridge {
        private static var application: NSObject? {
            (NSClassFromString("NSApplication") as? NSObject.Type)?
                .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        }

        private static var windows: [NSObject] {
            let all =
                application?.perform(NSSelectorFromString("windows"))?.takeUnretainedValue() as? [NSObject]
                ?? []
            let content = all.filter { $0.responds(to: NSSelectorFromString("setFrame:display:")) }
            // A file panel or alert keeps its own place and size.
            return content.filter {
                let name = NSStringFromClass(type(of: $0))
                return !name.contains("StatusBar") && !name.contains("Menu") && !name.contains("Panel")
                    && !name.contains("Alert")
            }
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

        /// Places every content window at `frame` and in front, only when it is not already there.
        static func hold(frame: WindowFrame) {
            let target = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            for window in windows {
                let current = (window.value(forKey: "frame") as? NSValue)?.cgRectValue
                let visible = window.value(forKey: "visible") as? Bool ?? false
                // Catalyst can put the title bar back when a scene updates, so this is checked too.
                prepare(window)
                if visible, current == target { continue }
                let selector = NSSelectorFromString("setFrame:display:")
                typealias Function = @convention(c) (AnyObject, Selector, CGRect, Bool) -> Void
                unsafeBitCast(window.method(for: selector), to: Function.self)(
                    window, selector, target, true)
                window.perform(NSSelectorFromString("orderFrontRegardless"))
            }
        }

        /// Puts the module's content windows in front, without taking keyboard focus.
        static func raise() {
            for window in windows {
                window.perform(NSSelectorFromString("orderFrontRegardless"))
            }
        }

        static func holdHidden() {
            for window in windows where window.value(forKey: "visible") as? Bool ?? false {
                window.perform(NSSelectorFromString("orderOut:"), with: nil)
            }
        }

        /// The dock's strip is the title bar: no window controls, and it moves only with the strip.
        private static func prepare(_ window: NSObject) {
            let titled = 1
            let fullSizeContentView = 1 << 15
            let wanted = titled | fullSizeContentView
            typealias SetMask = @convention(c) (AnyObject, Selector, Int) -> Void
            let mask = NSSelectorFromString("setStyleMask:")
            let isPrepared =
                (window.value(forKey: "styleMask") as? Int) == wanted
                && (window.value(forKey: "movable") as? Bool) == false
            if isPrepared { return }
            if window.responds(to: mask) {
                unsafeBitCast(window.method(for: mask), to: SetMask.self)(window, mask, wanted)
            }
            typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
            for (name, value) in [
                ("setMovable:", false), ("setTitlebarAppearsTransparent:", true),
            ] {
                let selector = NSSelectorFromString(name)
                if window.responds(to: selector) {
                    unsafeBitCast(window.method(for: selector), to: SetFlag.self)(
                        window, selector, value)
                }
            }
            typealias SetVisibility = @convention(c) (AnyObject, Selector, Int) -> Void
            let visibility = NSSelectorFromString("setTitleVisibility:")
            if window.responds(to: visibility) {
                unsafeBitCast(window.method(for: visibility), to: SetVisibility.self)(
                    window, visibility, 1)
            }
            typealias Button = @convention(c) (AnyObject, Selector, Int) -> AnyObject?
            let button = NSSelectorFromString("standardWindowButton:")
            if window.responds(to: button) {
                for kind in 0...2 {
                    let control = unsafeBitCast(window.method(for: button), to: Button.self)(
                        window, button, kind)
                    (control as? NSObject)?.setValue(true, forKey: "hidden")
                }
            }
        }
    }
#endif
