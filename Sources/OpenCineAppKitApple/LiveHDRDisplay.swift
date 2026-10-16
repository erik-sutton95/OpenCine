#if os(iOS)
    import Metal
    import MetalKit
    import MonitorUI
    import OpenCineApple
    import QuartzCore
    import SwiftUI
    import UIKit
    import os

    /// Outdoor HDR panel boost for live view and Metal scopes.
    ///
    /// The camera picture stays Rec.709 / log; this does not change COLOR or
    /// recording. WAVE / HISTO still measure decoded codes. When enabled, the
    /// Metal present path writes extended-linear values above SDR white so an
    /// HDR phone can drive the extra nits the panel reserves for HDR content.
    ///
    /// One instance per app (each app's `LiveHDRDisplay.app`): the operator preference, screen
    /// capture and the panel's headroom are phone state the feed, scopes and chrome all read.
    public final class LiveHDRDisplay: Sendable {
        /// Peak linear ratio versus SDR white. Clamped to the screen's potential.
        public static let requestedHeadroom: CGFloat = 3
        /// Bake stays 8-bit display-referred. Only the drawable is float EDR.
        public static let bakePixelFormat: MTLPixelFormat = .bgra8Unorm

        private struct State {
            var preferredEnabled = false
            var screenCaptured = false
            var isEnabled = false
            var presentGain: Float = 1
            var chromeActive = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        public init() {}

        /// Operator Setup toggle. Present path reads ``isEnabled``.
        public var preferredEnabled: Bool { state.withLock { $0.preferredEnabled } }
        /// Screen recording, AirPlay, or mirroring: SDR so the file is not HDR-boosted.
        public var screenCaptured: Bool { state.withLock { $0.screenCaptured } }
        /// Effective: preferred and not captured. Feed, scopes and chrome read this.
        public var isEnabled: Bool { state.withLock { $0.isEnabled } }
        public var presentGain: Float { state.withLock { $0.presentGain } }
        public var chromeActive: Bool { state.withLock { $0.chromeActive } }

        public var chromeGain: Float { state.withLock { $0.isEnabled ? $0.presentGain : 1 } }

        public static func isEffective(preferred: Bool, screenCaptured: Bool) -> Bool {
            preferred && !screenCaptured
        }

        public static func drawablePixelFormat(enabled: Bool) -> MTLPixelFormat {
            enabled ? .rgba16Float : .bgra8Unorm
        }

        /// `potentialHeadroom` is `UIScreen.potentialEDRHeadroom` (1 on SDR panels).
        public static func displayGain(enabled: Bool, potentialHeadroom: CGFloat) -> Float {
            guard enabled else { return 1 }
            let cap = potentialHeadroom.isFinite ? max(potentialHeadroom, 1) : 1
            return Float(min(requestedHeadroom, cap))
        }

        @MainActor public func setEnabled(_ enabled: Bool, screen: UIScreen? = UIScreen.main) {
            state.withLock { $0.preferredEnabled = enabled }
            apply(screen: screen)
        }

        @MainActor public func setScreenCaptured(_ captured: Bool, screen: UIScreen? = UIScreen.main) {
            state.withLock { $0.screenCaptured = captured }
            apply(screen: screen)
        }

        public func setChromeActive(_ active: Bool) {
            state.withLock { $0.chromeActive = active && $0.isEnabled }
            MonitorTheme.hdrGain = CGFloat(chromeGain)
        }

        @MainActor private func apply(screen: UIScreen?) {
            state.withLock {
                $0.isEnabled = Self.isEffective(
                    preferred: $0.preferredEnabled, screenCaptured: $0.screenCaptured)
                $0.chromeActive = $0.isEnabled
            }
            refreshGain(screen: screen)
            MonitorTheme.hdrGain = CGFloat(chromeGain)
        }

        public func chromeColor(
            red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1
        ) -> Color {
            MonitorTheme.edrSRGB(
                red: red, green: green, blue: blue, gain: CGFloat(chromeGain), alpha: alpha)
        }

        public func chromeColor(hex: UInt32, alpha: CGFloat = 1) -> Color {
            chromeColor(
                red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255,
                alpha: alpha)
        }

        @MainActor public func refreshGain(screen: UIScreen?) {
            let potential = screen?.potentialEDRHeadroom ?? 1
            state.withLock {
                $0.presentGain = Self.displayGain(enabled: $0.isEnabled, potentialHeadroom: potential)
            }
        }

        /// Runs on every feed present; the native layer writes only what changed.
        @MainActor public func configure(_ layer: CAMetalLayer, screen: UIScreen? = nil) {
            refreshGain(screen: screen ?? UIScreen.main)
            MonitorHDRDisplay.configure(layer, enabled: isEnabled)
        }

        @MainActor public func configure(_ view: MTKView, screen: UIScreen? = nil) {
            let format = Self.drawablePixelFormat(enabled: isEnabled)
            if view.colorPixelFormat != format {
                view.colorPixelFormat = format
            }
            if let layer = view.layer as? CAMetalLayer {
                configure(layer, screen: screen ?? view.window?.screen)
            }
        }

        @MainActor public func configure(_ layer: CALayer, screen: UIScreen? = nil, enabled: Bool? = nil) {
            refreshGain(screen: screen ?? UIScreen.main)
            let on = enabled ?? isEnabled
            layer.wantsExtendedDynamicRangeContent = on
            if #available(iOS 26.0, *) {
                layer.preferredDynamicRange = on ? .high : .automatic
            }
        }
    }

    extension View {
        /// The app root's HDR display composition, one for every app (A2-31): the live chrome's
        /// HDR gain, the EDR window host and screen-capture tracking, so screen recording,
        /// AirPlay and mirroring drop back to SDR. `active` is the effective choice (the operator
        /// preference and not captured); `screenCaptured` follows the main screen.
        public func monitorHDRDisplay(_ display: LiveHDRDisplay, active: Bool,
            screenCaptured: Binding<Bool>) -> some View {
            modifier(MonitorHDRDisplayRoot(display: display, active: active, screenCaptured: screenCaptured))
        }
    }

    private struct MonitorHDRDisplayRoot: ViewModifier {
        let display: LiveHDRDisplay
        let active: Bool
        let screenCaptured: Binding<Bool>

        func body(content: Content) -> some View {
            content
                .environment(\.monitorHDRChromeGain, active ? CGFloat(display.presentGain) : 1)
                .background { HDRChromeHost(display: display, enabled: active).allowsHitTesting(false) }
                .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                    screenCaptured.wrappedValue = UIScreen.main.isCaptured
                }
                .onAppear { screenCaptured.wrappedValue = UIScreen.main.isCaptured }
        }
    }

    /// Enables EDR on the live window so SwiftUI HUD labels can exceed SDR white.
    public struct HDRChromeHost: UIViewRepresentable {
        public var display: LiveHDRDisplay
        public var enabled: Bool

        public init(display: LiveHDRDisplay, enabled: Bool) {
            self.display = display
            self.enabled = enabled
        }

        public func makeUIView(context: Context) -> Probe {
            Probe(display: display)
        }

        public func updateUIView(_ uiView: Probe, context: Context) {
            uiView.enabled = enabled
            uiView.apply()
        }

        public final class Probe: UIView {
            let display: LiveHDRDisplay
            var enabled = false
            private weak var trackedWindow: UIWindow?

            init(display: LiveHDRDisplay) {
                self.display = display
                super.init(frame: .zero)
                isUserInteractionEnabled = false
                backgroundColor = .clear
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

            override public func didMoveToWindow() {
                super.didMoveToWindow()
                apply()
            }

            func apply() {
                let on = enabled && window != nil
                display.setChromeActive(on)
                if let previous = trackedWindow, previous !== window {
                    display.configure(previous.layer, screen: previous.screen, enabled: false)
                }
                trackedWindow = window
                if let window {
                    display.configure(window.layer, screen: window.screen, enabled: on)
                }
            }
        }
    }
#endif
