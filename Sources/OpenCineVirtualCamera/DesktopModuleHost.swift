#if targetEnvironment(macCatalyst)
    import Foundation
    import ObjectiveC
    import OpenCineDesktopKit
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
            let input = FileHandle(fileDescriptor: 0, closeOnDealloc: false)
            input.readabilityHandler = { [weak self] file in
                let data = file.availableData
                // The dock going away must not take a live camera with it.
                guard !data.isEmpty else {
                    file.readabilityHandler = nil
                    return
                }
                Task { @MainActor [weak self] in self?.received(data) }
            }
            send(.ready(moduleID: moduleID))
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
                case .show(let frame): AppKitBridge.show(frame: frame)
                case .hide: AppKitBridge.hide()
                case .quit: exit(0)
                }
            }
        }

        private func send(_ message: ModuleMessage) {
            guard let data = try? LengthPrefixedJSON.encode(message) else { return }
            try? FileHandle(fileDescriptor: 0, closeOnDealloc: false).write(contentsOf: data)
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
            return content.filter {
                !NSStringFromClass(type(of: $0)).contains("StatusBar")
                    && !NSStringFromClass(type(of: $0)).contains("Menu")
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

        static func show(frame: WindowFrame) {
            for window in windows {
                prepare(window)
                let selector = NSSelectorFromString("setFrame:display:")
                typealias Function = @convention(c) (AnyObject, Selector, CGRect, Bool) -> Void
                unsafeBitCast(window.method(for: selector), to: Function.self)(
                    window, selector,
                    CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), true)
                window.perform(NSSelectorFromString("orderFrontRegardless"))
            }
        }

        static func hide() {
            for window in windows {
                window.perform(NSSelectorFromString("orderOut:"), with: nil)
            }
        }

        /// The dock's strip is the title bar: no window controls, and it moves only with the strip.
        private static func prepare(_ window: NSObject) {
            let titled = 1
            let fullSizeContentView = 1 << 15
            typealias SetMask = @convention(c) (AnyObject, Selector, Int) -> Void
            let mask = NSSelectorFromString("setStyleMask:")
            if window.responds(to: mask) {
                unsafeBitCast(window.method(for: mask), to: SetMask.self)(
                    window, mask, titled | fullSizeContentView)
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
