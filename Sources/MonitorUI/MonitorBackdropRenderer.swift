#if os(iOS)
    import CoreGraphics
    import MonitorPresentation
    import SwiftUI

    public typealias MonitorGlassDensity = MonitorPresentation.MonitorGlassDensity

    /// A passive displayed-look image and its placement in the monitor canvas.
    /// Multiple layers permit multiview without a separate backdrop per widget.
    public struct MonitorBackdropLayer: @unchecked Sendable {
        public var image: CGImage
        public var frame: CGRect
        public var clip: CGRect

        public init(image: CGImage, frame: CGRect, clip: CGRect) {
            self.image = image
            self.frame = frame
            self.clip = clip
        }
    }

    public struct MonitorBackdropSnapshot: @unchecked Sendable {
        public let canvasSize: CGSize
        private let images: [MonitorGlassDensity: CGImage]

        public func image(for density: MonitorGlassDensity) -> CGImage? { images[density] }

        public init(canvasSize: CGSize, images: [MonitorGlassDensity: CGImage]) {
            self.canvasSize = canvasSize
            self.images = images
        }
    }

    struct MonitorBackdropEnvironment {
        var snapshot: MonitorBackdropSnapshot?
        var frame: CGRect = .zero
    }

    /// A live owner's changing backdrop, shared by reference. The environment
    /// carries only this stable object, so a 25 Hz product reaches just the glass
    /// backgrounds that read it; changing an environment value instead made
    /// SwiftUI re-check every environment dependency under the live chrome.
    @Observable
    public final class MonitorBackdropSource {
        public var snapshot: MonitorBackdropSnapshot?
        public var frame: CGRect = .zero
        public init() {}
    }

    private struct MonitorBackdropSourceKey: EnvironmentKey {
        static var defaultValue: MonitorBackdropSource? { nil }
    }

    private struct MonitorBackdropKey: EnvironmentKey {
        static let defaultValue = MonitorBackdropEnvironment()
    }

    extension EnvironmentValues {
        var monitorBackdrop: MonitorBackdropEnvironment {
            get { self[MonitorBackdropKey.self] }
            set { self[MonitorBackdropKey.self] = newValue }
        }

        var monitorBackdropSource: MonitorBackdropSource? {
            get { self[MonitorBackdropSourceKey.self] }
            set { self[MonitorBackdropSourceKey.self] = newValue }
        }
    }

    extension View {
        /// The native shell owns cadence/lifecycle and injects a single product.
        public func monitorBackdrop(_ snapshot: MonitorBackdropSnapshot?, in globalFrame: CGRect)
            -> some View
        {
            environment(
                \.monitorBackdrop,
                MonitorBackdropEnvironment(snapshot: snapshot, frame: globalFrame))
        }

        /// Live owners: pass one retained source and update it off the view body.
        public func monitorBackdrop(source: MonitorBackdropSource) -> some View {
            environment(\.monitorBackdropSource, source)
        }
    }
#endif
