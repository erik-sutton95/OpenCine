#if canImport(Foundation)
    import Foundation

    /// Native capture-device admission, separate from device discovery and session mutation.
    public enum UVCCaptureSelection {
        /// A remembered missing source remains missing; explicit mode never opens a fallback camera.
        public static func deviceID(
            available: [String], preferred: String?, requiresExplicitSelection: Bool
        ) -> String? {
            if let preferred { return available.contains(preferred) ? preferred : nil }
            return requiresExplicitSelection ? nil : available.first
        }
    }

    /// One requested native capture mode. The device must advertise the complete request.
    public struct UVCCaptureMode: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let framesPerSecond: Double

        public init(width: Int, height: Int, framesPerSecond: Double) {
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
        }

        public func matches(width: Int, height: Int, minimumRate: Double, maximumRate: Double)
            -> Bool
        {
            self.width > 0 && self.height > 0 && framesPerSecond.isFinite && framesPerSecond > 0
                && self.width == width && self.height == height
                && minimumRate.isFinite && maximumRate.isFinite
                && framesPerSecond >= minimumRate && framesPerSecond <= maximumRate
        }
    }

#endif
