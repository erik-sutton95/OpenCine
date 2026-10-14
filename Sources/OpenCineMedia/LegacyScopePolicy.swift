import Foundation

/// Resolved host values; this policy neither selects a source nor reads camera metadata.
public struct LegacyScopeCalibration: Equatable, Sendable {
    public let blackNative: Double
    public let middleGrayNative: Double
    public let clipNative: Double
    public let defaultClipNative: Double
    public let crushUpperNative: Double

    public init(blackNative: Double, middleGrayNative: Double, clipNative: Double,
        defaultClipNative: Double, crushUpperNative: Double) {
        self.blackNative = blackNative; self.middleGrayNative = middleGrayNative
        self.clipNative = clipNative; self.defaultClipNative = defaultClipNative
        self.crushUpperNative = crushUpperNative
    }
}

/// Legacy compatibility math only; current scope engines do not select this policy.
public enum LegacyScopePolicy {
    public static let legalBlackCode: Double = 16
    public static let legalWhiteCode: Double = 235
    public static let crushLineLevel = 0.05
    public static let clipLineLevel = 0.95
    public static func nativeCodeLevel(signalNative: Double) -> Double {
        min(255, max(0, signalNative)) / 255.0
    }
    public static func waveformLevel(
        signalNative: Double, calibration: LegacyScopeCalibration
    ) -> Double {
        let native = min(255, max(0, signalNative))
        let black = calibration.blackNative
        let mid = calibration.middleGrayNative
        let clip = max(calibration.clipNative, mid + 1)
        let midLevel = middleGrayLevel(calibration: calibration)
        if native < black {
            guard black > 0 else { return crushLineLevel }
            return native / black * crushLineLevel
        }
        if native <= mid {
            return crushLineLevel + (native - black) / (mid - black)
                * (midLevel - crushLineLevel)
        }
        if native <= clip {
            return midLevel + (native - mid) / (clip - mid) * (clipLineLevel - midLevel)
        }
        let headroom = 255 - clip
        guard headroom > 0 else { return clipLineLevel }
        return clipLineLevel + (native - clip) / headroom * (1 - clipLineLevel)
    }
    public static func middleGrayLevel(calibration: LegacyScopeCalibration) -> Double {
        let black = calibration.blackNative
        let mid = calibration.middleGrayNative
        let defaultClip = max(calibration.defaultClipNative, mid + 1)
        return crushLineLevel + (mid - black) / (defaultClip - black)
            * (clipLineLevel - crushLineLevel)
    }

    public static func remapHistogram(
        _ histogram: [Int], calibration: LegacyScopeCalibration
    ) -> [Double] {
        var out = [Double](repeating: 0, count: 256)
        guard histogram.count == 256 else { return out }
        for native in 0..<256 {
            let level = waveformLevel(signalNative: Double(native), calibration: calibration)
            let bucket = min(255, max(0, Int((level * 255).rounded())))
            out[bucket] += Double(histogram[native])
        }
        return out
    }

    public static func trafficLights(
        samples: ScopeSamples, calibration: LegacyScopeCalibration, threshold: Double = 0.10
    ) -> LegacyHistogramTrafficLights {
        trafficLights(
            red: samples.histogramRed, green: samples.histogramGreen,
            blue: samples.histogramBlue, calibration: calibration, threshold: threshold)
    }

    public static func medianWaveformLevel(
        points: [ScopePoint], calibration: LegacyScopeCalibration, channel: (ScopePoint) -> UInt8
    ) -> Double {
        guard !points.isEmpty else { return 0 }
        var levels = ContiguousArray<Double>()
        levels.reserveCapacity(points.count)
        for point in points {
            levels.append(
                waveformLevel(
                    signalNative: Double(channel(point)), calibration: calibration))
        }
        let mid = levels.count / 2
        if levels.count.isMultiple(of: 2) {
            let lower = orderStatistic(&levels, rank: mid - 1)
            let upper = orderStatistic(&levels, rank: mid)
            return (lower + upper) / 2
        }
        return orderStatistic(&levels, rank: mid)
    }
    private static func orderStatistic(_ values: inout ContiguousArray<Double>, rank: Int) -> Double
    {
        var low = 0
        var high = values.count - 1
        while low < high {
            let pivotIndex = partition(&values, low: low, high: high)
            if pivotIndex == rank { return values[pivotIndex] }
            if pivotIndex < rank {
                low = pivotIndex + 1
            } else {
                high = pivotIndex - 1
            }
        }
        return values[low]
    }

    private static func partition(
        _ values: inout ContiguousArray<Double>, low: Int, high: Int
    ) -> Int {
        let pivotValue = values[high]
        var storeIndex = low
        for index in low..<high where values[index] < pivotValue {
            values.swapAt(index, storeIndex)
            storeIndex += 1
        }
        values.swapAt(storeIndex, high)
        return storeIndex
    }

    public static func medianWaveformLevel(
        histogram: [Int], calibration: LegacyScopeCalibration
    ) -> Double {
        guard histogram.count == 256 else { return 0 }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let target = total / 2
        var cumulative = 0
        for native in 0..<256 {
            cumulative += histogram[native]
            if cumulative > target || (cumulative == target && total.isMultiple(of: 2)) {
                return waveformLevel(
                    signalNative: Double(native), calibration: calibration)
            }
        }
        return waveformLevel(signalNative: 255, calibration: calibration)
    }

    public static func trafficLights(
        red: [Int], green: [Int], blue: [Int], calibration: LegacyScopeCalibration,
        threshold: Double = 0.10
    ) -> LegacyHistogramTrafficLights {
        let clipEdge = trafficClipEdge(calibration: calibration)
        let crushFloor = trafficCrushFloor(calibration: calibration)
        let crushEdge = trafficCrushEdge(calibration: calibration)
        func clips(_ histogram: [Int]) -> Bool {
            edgeEnergy(histogram, from: clipEdge, to: 255) > threshold
        }
        func crushes(_ histogram: [Int]) -> Bool {

            edgeEnergy(histogram, from: crushFloor, to: crushEdge) > threshold
        }
        return LegacyHistogramTrafficLights(
            crushRed: crushes(red), crushGreen: crushes(green), crushBlue: crushes(blue),
            clipRed: clips(red), clipGreen: clips(green), clipBlue: clips(blue))
    }

    public static func trafficClipEdge(calibration: LegacyScopeCalibration) -> Int {
        min(
            255,
            max(0, Int(calibration.clipNative.rounded(.up))))
    }

    public static func trafficCrushFloor(calibration: LegacyScopeCalibration) -> Int {
        min(
            255,
            max(0, Int(calibration.blackNative.rounded(.down))))
    }

    public static func trafficCrushEdge(calibration: LegacyScopeCalibration) -> Int {
        min(
            255,
            max(0, Int(calibration.crushUpperNative.rounded(.up))))
    }
    private static func edgeEnergy(_ histogram: [Int], from: Int, to: Int) -> Double {
        guard histogram.count == 256, from <= to, from >= 0, to <= 255 else { return 0 }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        return Double(histogram[from...to].reduce(0, +)) / Double(total)
    }
}

public struct LegacyHistogramTrafficLights: Equatable, Sendable {
    public var crushRed: Bool
    public var crushGreen: Bool
    public var crushBlue: Bool
    public var clipRed: Bool
    public var clipGreen: Bool
    public var clipBlue: Bool

    public init(
        crushRed: Bool, crushGreen: Bool, crushBlue: Bool,
        clipRed: Bool, clipGreen: Bool, clipBlue: Bool
    ) {
        self.crushRed = crushRed
        self.crushGreen = crushGreen
        self.crushBlue = crushBlue
        self.clipRed = clipRed
        self.clipGreen = clipGreen
        self.clipBlue = clipBlue
    }

    public static let none = LegacyHistogramTrafficLights(
        crushRed: false, crushGreen: false, crushBlue: false,
        clipRed: false, clipGreen: false, clipBlue: false)
}

public enum LegacyTrafficLightsBarSide: Equatable, Sendable {

    case neutral

    case over

    case under
}

public struct LegacyTrafficLightsChannelDisplay: Equatable, Sendable {

    public let side: LegacyTrafficLightsBarSide

    public let barFill: Double

    public init(side: LegacyTrafficLightsBarSide, barFill: Double) {
        self.side = side
        self.barFill = min(1, max(0, barFill))
    }

    public static let neutral = LegacyTrafficLightsChannelDisplay(side: .neutral, barFill: 0)
}

public struct LegacyTrafficLightsChannelReading: Equatable, Sendable {

    public let level: Double

    public let clip: Bool

    public let crush: Bool

    public init(level: Double, clip: Bool, crush: Bool) {
        self.level = min(1, max(0, level))
        self.clip = clip
        self.crush = crush
    }
}

public struct LegacyTrafficLightsReading: Equatable, Sendable {
    public let red: LegacyTrafficLightsChannelReading
    public let green: LegacyTrafficLightsChannelReading
    public let blue: LegacyTrafficLightsChannelReading

    public init(
        red: LegacyTrafficLightsChannelReading,
        green: LegacyTrafficLightsChannelReading,
        blue: LegacyTrafficLightsChannelReading
    ) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let empty = LegacyTrafficLightsReading(
        red: LegacyTrafficLightsChannelReading(level: 0, clip: false, crush: false),
        green: LegacyTrafficLightsChannelReading(level: 0, clip: false, crush: false),
        blue: LegacyTrafficLightsChannelReading(level: 0, clip: false, crush: false))
}

public enum LegacyTrafficLightsChannel: Sendable {
    case red, green, blue
}

public enum LegacyTrafficLightsMeter {

    public static func measure(
        samples: ScopeSamples,
        noiseFloorCompensation: MonitorCrushClipCompensation,
        calibration: LegacyScopeCalibration
    ) -> LegacyTrafficLightsReading {
        let threshold = noiseFloorCompensation.pixelFractionThreshold
        let lights = LegacyScopePolicy.trafficLights(
            samples: samples, calibration: calibration, threshold: threshold)
        return LegacyTrafficLightsReading(
            red: channelReading(
                samples: samples, channel: .red, clip: lights.clipRed, crush: lights.crushRed,
                calibration: calibration),
            green: channelReading(
                samples: samples, channel: .green, clip: lights.clipGreen,
                crush: lights.crushGreen, calibration: calibration),
            blue: channelReading(
                samples: samples, channel: .blue, clip: lights.clipBlue, crush: lights.crushBlue,
                calibration: calibration))
    }

    public static func channelLevel(
        samples: ScopeSamples, channel: LegacyTrafficLightsChannel, calibration: LegacyScopeCalibration
    ) -> Double {
        let histogram = histogram(for: channel, in: samples)
        if histogram.contains(where: { $0 > 0 }) {
            return channelLevel(histogram: histogram, calibration: calibration)
        }
        if !samples.points.isEmpty {
            let level = LegacyScopePolicy.medianWaveformLevel(
                points: samples.points, calibration: calibration, channel: nativeValue(for: channel))
            return balanceLevel(level, calibration: calibration)
        }
        return 0
    }

    public static func channelLevel(
        histogram: [Int], calibration: LegacyScopeCalibration
    ) -> Double {
        balanceLevel(
            LegacyScopePolicy.medianWaveformLevel(histogram: histogram, calibration: calibration),
            calibration: calibration)
    }

    private static func balanceLevel(
        _ scopeLevel: Double, calibration: LegacyScopeCalibration
    ) -> Double {
        let middle = LegacyScopePolicy.middleGrayLevel(calibration: calibration)
        if scopeLevel <= middle {
            return middle > 0 ? (scopeLevel / middle) * 0.5 : 0
        }
        let upperSpan = max(1 - middle, .leastNonzeroMagnitude)
        return 0.5 + ((scopeLevel - middle) / upperSpan) * 0.5
    }

    private static func channelReading(
        samples: ScopeSamples, channel: LegacyTrafficLightsChannel, clip: Bool, crush: Bool,
        calibration: LegacyScopeCalibration
    ) -> LegacyTrafficLightsChannelReading {
        LegacyTrafficLightsChannelReading(
            level: channelLevel(samples: samples, channel: channel, calibration: calibration),
            clip: clip,
            crush: crush)
    }

    private static func histogram(for channel: LegacyTrafficLightsChannel, in samples: ScopeSamples)
        -> [Int]
    {
        switch channel {
        case .red: samples.histogramRed
        case .green: samples.histogramGreen
        case .blue: samples.histogramBlue
        }
    }

    private static func nativeValue(for channel: LegacyTrafficLightsChannel) -> (ScopePoint) -> UInt8 {
        switch channel {
        case .red: { $0.red }
        case .green: { $0.green }
        case .blue: { $0.blue }
        }
    }

    public static let balanceCenter = 0.5

    public static let balanceDeadZone = 0.03

    public static func channelDisplay(
        for reading: LegacyTrafficLightsChannelReading,
        balanceCenter center: Double = balanceCenter,
        deadZone: Double = balanceDeadZone
    ) -> LegacyTrafficLightsChannelDisplay {
        let deviation = reading.level - center
        if abs(deviation) <= deadZone {
            return .neutral
        }
        if deviation > 0 {
            let span = max(1 - center, .leastNonzeroMagnitude)
            return LegacyTrafficLightsChannelDisplay(
                side: .over, barFill: min(1, deviation / span))
        }
        let span = max(center, .leastNonzeroMagnitude)
        return LegacyTrafficLightsChannelDisplay(
            side: .under, barFill: min(1, abs(deviation) / span))
    }
}
