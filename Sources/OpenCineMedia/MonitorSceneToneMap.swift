import Foundation

/// A scene-linear to display-code transform with an explicitly supplied scene-white point.
/// Camera signal decoding and measured clipping endpoints belong to the source adapter.
public struct MonitorSceneToneMap: Equatable, Sendable {
    public static let middleGrayDisplayLinear = pow(0.42, 2.4)
    public static let defaultContrast = 1.1

    public let contrast: Double
    public let whitePoint: Double
    private let gain: Double
    private let whiteReinhard: Double

    public init(sceneWhite: Double, contrast: Double = Self.defaultContrast) {
        self.contrast = contrast
        let whitePoint = max(sceneWhite / 0.18, 0.000_001)
        self.whitePoint = whitePoint
        let contrastedWhite = pow(whitePoint, contrast)
        let whiteContribution = 1 / (contrastedWhite * contrastedWhite)
        let numerator = Self.middleGrayDisplayLinear - whiteContribution
        let gain = max(0.000_001, numerator / (1 - Self.middleGrayDisplayLinear))
        self.gain = gain
        whiteReinhard = gain * contrastedWhite
    }

    public func displayLinear(sceneLinear: Double) -> Double {
        let x = max(0, sceneLinear) / 0.18
        let contrasted = gain * pow(x, contrast)
        let white = whiteReinhard
        let mapped = contrasted * (1 + contrasted / (white * white)) / (1 + contrasted)
        return min(1, max(0, mapped))
    }

    public func displayCode(sceneLinear: Double) -> Double {
        pow(displayLinear(sceneLinear: sceneLinear), 1 / 2.4)
    }

    public func ire(sceneLinear: Double) -> Double {
        displayCode(sceneLinear: sceneLinear) * 100
    }
}
