#if canImport(CoreImage)
import Foundation
import OpenCineMedia

extension MonitorFrameEffects {
    public func nativeImageEffects(using mapper: MonitorFalseColorMapper?) -> MonitorImageEffects {
        var result = nativeImagePlan
        if falseColor, let maps = mapper?.overlayPairData(scale: falseColorScale.liveScale,
            transfer: transfer, rec709: falseColorRec709, clipByte: resolvedClipByte) {
            result.falseColorMaps = MonitorOverlayMaps(dimension: maps.dimension, paint: maps.paint, weight: maps.weight)
        }
        return result
    }
    public var nativeImagePlan: OpenCineApple.MonitorImageEffects {
        var result = OpenCineApple.MonitorImageEffects()
        result.peaking = peaking; result.zebra = zebra; result.falseColor = falseColor
        result.lutDimension = lutDimension; result.lutRGBA = lutRGBA
        result.peakingColor = OpenCineApple.MonitorRGB(peakingColor.rgb)
        result.peakingSensitivity = OpenCineApple.MonitorPeakingSensitivity(
            ratioThreshold: peakingSensitivity.ratioThreshold, noiseGate: peakingSensitivity.noiseGate)
        result.peakingGateScale = transfer == .rec709 || transfer == .hdr
            ? Peaking.gateScale(gradientScale: Peaking.displayReferredGradientScale) : 1
        result.transfer = transfer; result.clipByte = resolvedClipByte
        result.zebraSpec = OpenCineApple.MonitorZebraSpec(
            highlightEnabled: zebraHighlight, highlightIRE: zebraHighlightIRE,
            highlightColor: OpenCineApple.MonitorRGB(zebraHighlightColor.rgb),
            midtoneEnabled: zebraMidtone, midtoneIRE: zebraMidtoneIRE,
            midtoneColor: OpenCineApple.MonitorRGB(zebraMidtoneColor.rgb))
        result.falseColorPaintsFullFrame = falseColor && falseColorScale != .limits
        result.splitComparison = splitComparison; result.splitVertical = splitVertical
        result.desqueezeFactor = desqueezeFactor; result.desqueezeHorizontal = desqueezeHorizontal
        return result
    }
}

extension MonitorFrameEffects {
    public var nativeAssistPolicy: OpenCineApple.MonitorAssistPolicy {
        var result = OpenCineApple.MonitorAssistPolicy()
        result.image = nativeImagePlan
        result.histogram = histogram; result.waveform = waveform; result.parade = parade
        result.vectorscope = vectorscope; result.trafficLights = trafficLights
        result.ndMeter = ndMeter; result.evMeter = evMeter
        result.trafficThreshold = trafficThreshold
        result.allowsTransferInference = allowsTransferInference
        switch falseColorScale {
        case .sceneStops: result.falseColorScale = .sceneStops
        case .stops: result.falseColorScale = .stops
        case .ire: result.falseColorScale = .ire
        case .limits: result.falseColorScale = .limits
        }
        result.falseColorRec709 = falseColorRec709
        return result
    }
}

#endif
