import Foundation
import OpenCineCore

/// The interface lock's rotation hold. While the monitor is
/// locked the screen keeps the orientation it had when the lock engaged, so an operator who
/// levels an inverted rig does not see the monitor flip. Unlocking releases it, and so does the
/// monitor going away.
///
/// `Value` is the platform's orientation fact: on iOS the interface orientation to hold, on
/// Android the activity's previous orientation request to restore.
///
/// Kotlin mirror: `MonitorRotationHold` in `:appkit`, same names.
public struct MonitorRotationHold<Value: Equatable & Sendable>: Equatable, Sendable {
    /// The captured value while the lock holds; nil when free.
    public private(set) var held: Value?

    public init() {}

    /// Engaging the lock captures `current` once; while `current` is unknown (nil) the capture
    /// waits for the first known value. Later turns keep the capture; unlocking drops it.
    /// Returns true when `held` changed.
    @discardableResult
    public mutating func update(locked: Bool, current: Value?) -> Bool {
        let previous = held
        if !locked {
            held = nil
        } else if held == nil {
            held = current
        }
        return held != previous
    }
}

#if os(iOS)
    import MonitorUI
    import SwiftUI
    import UIKit

    /// The app's rotation hold on iOS. The app delegate answers
    /// `application(_:supportedInterfaceOrientationsFor:)` with `supportedOrientations` and hands
    /// the same instance to its monitor with `.monitorRotationLock(_:)`; the live surface engages
    /// it with the interface lock. Without the delegate answer the screen keeps turning.
    ///
    /// The held orientation is the scene's interface orientation, so an inverted landscape rig
    /// holds the other landscape. Portrait upside down is only held where the device offers it
    /// (iPad; Face ID iPhones never rotate to it).
    @MainActor
    public final class MonitorRotationLock {
        private var hold = MonitorRotationHold<UIInterfaceOrientation>()
        private let released: UIInterfaceOrientationMask

        /// `released` is what the app allows while unlocked; by default the orientations its
        /// Info.plist declares for this device.
        public init(released: UIInterfaceOrientationMask? = nil) {
            self.released = released ?? Self.declaredOrientations()
        }

        /// The held orientation while the lock holds, else nil.
        public var heldOrientation: UIInterfaceOrientation? { hold.held }

        /// The app delegate's answer for every window.
        public var supportedOrientations: UIInterfaceOrientationMask {
            hold.held.map(Self.mask(for:)) ?? released
        }

        /// Engages (captures the current interface orientation) or releases the hold.
        public func update(locked: Bool) {
            let scene = Self.activeScene()
            let current = scene.map(\.interfaceOrientation).flatMap { $0 == .unknown ? nil : $0 }
            guard hold.update(locked: locked, current: current) else { return }
            for window in scene?.windows ?? [] {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }

        public static func mask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
            switch orientation {
            case .portrait: .portrait
            case .portraitUpsideDown: .portraitUpsideDown
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            case .unknown: .all
            @unknown default: .all
            }
        }

        private static func activeScene() -> UIWindowScene? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return scenes.first { $0.activationState == .foregroundActive }
                ?? scenes.first { $0.activationState == .foregroundInactive }
                ?? scenes.first
        }

        private static func declaredOrientations() -> UIInterfaceOrientationMask {
            let pad = HostDevice.current.isLargeScreen
            let key = pad ? "UISupportedInterfaceOrientations~ipad" : "UISupportedInterfaceOrientations"
            let names = Bundle.main.object(forInfoDictionaryKey: key) as? [String]
                ?? Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String]
                ?? []
            let mask = names.reduce(into: UIInterfaceOrientationMask()) { mask, name in
                switch name {
                case "UIInterfaceOrientationPortrait": mask.insert(.portrait)
                case "UIInterfaceOrientationPortraitUpsideDown": mask.insert(.portraitUpsideDown)
                case "UIInterfaceOrientationLandscapeLeft": mask.insert(.landscapeLeft)
                case "UIInterfaceOrientationLandscapeRight": mask.insert(.landscapeRight)
                default: break
                }
            }
            return mask.isEmpty ? .all : mask
        }
    }

    private struct MonitorRotationLockKey: EnvironmentKey {
        static let defaultValue: MonitorRotationLock? = nil
    }

    extension EnvironmentValues {
        /// The app's rotation hold, nil when the app does not offer one.
        public var monitorRotationLock: MonitorRotationLock? {
            get { self[MonitorRotationLockKey.self] }
            set { self[MonitorRotationLockKey.self] = newValue }
        }
    }

    extension View {
        /// Hands the app's rotation hold to the monitors below.
        public func monitorRotationLock(_ lock: MonitorRotationLock) -> some View {
            environment(\.monitorRotationLock, lock)
        }

        /// The live surface's side: holds the screen's rotation while `locked` and releases it
        /// when the surface leaves. Does nothing when the app offers no rotation hold.
        public func monitorHoldsRotation(locked: Bool) -> some View {
            modifier(MonitorRotationHoldModifier(locked: locked))
        }
    }

    private struct MonitorRotationHoldModifier: ViewModifier {
        let locked: Bool
        @Environment(\.monitorRotationLock) private var lock

        func body(content: Content) -> some View {
            content
                .onAppear { lock?.update(locked: locked) }
                .onChange(of: locked) { _, value in lock?.update(locked: value) }
                .onDisappear { lock?.update(locked: false) }
        }
    }
#endif
