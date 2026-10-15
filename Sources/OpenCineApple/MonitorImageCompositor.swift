#if canImport(CoreImage) && canImport(Metal)
import CoreImage
import Foundation
import Metal
import OpenCineMedia

private typealias Peak = Peaking

/// Additional analysis-window admission after the fused detector passes its runtime probe.
/// This is an Apple Core Image graph policy; renderer calibration and source settings stay values.
public enum MonitorPeakingFusedWindowPolicy: Equatable, Sendable {
    /// Preserve the shared renderer's existing rejection of analysed windows at most eight pixels.
    case extendedAnalysisWindow
    /// Attempt the admitted kernel without an additional window-size rejection.
    /// A kernel that cannot apply still uses the unchanged filter-chain fallback.
    case admittedKernel
}

/// Encoded camera codes (encoded by the source). Default Core Image linearizes a Rec.709
/// tag - or treats an untagged cube result as linear and DeviceRGB-encodes it. Either
/// way the official log→709 cube looks like uncorrected log (lifted blacks, dull reds).
public enum MonitorWorkingSpace {
    /// LUT / false-colour cubes on encoded camera codes. Do not use for HEVC identity.
    public static var contextOptions: [CIContextOption: Any] {
        [
            .workingFormat: CIFormat.BGRA8,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
    }

    /// Rec.709 / HLG identity present. YUV→RGB needs the buffer's color attachments.
    public static var displayContextOptions: [CIContextOption: Any] {
        [
            .workingFormat: CIFormat.BGRA8,
            .cacheIntermediates: false,
        ]
    }

    public static var imageOptions: [CIImageOption: Any] {
        [.colorSpace: NSNull()]
    }

    public static var displayImageOptions: [CIImageOption: Any] {
        if let rec709 = CGColorSpace(name: CGColorSpace.itur_709) {
            return [.colorSpace: rec709]
        }
        return [.colorSpace: CGColorSpaceCreateDeviceRGB()]
    }

    /// Metal `render(..., colorSpace:)` is non-optional. With the NSNull working
    /// space above, DeviceRGB is a required handle - it does not apply another OETF.
    public static let metalDestination = CGColorSpaceCreateDeviceRGB()
}

public enum MonitorImageCompositor {
    /// Working-width cap when the drawable is unknown at this site (the assist engine has
    /// no layer). Peaking / zebra / false colour are display-referred - evaluating their
    /// convolution graphs over the full 4K extent was the top heat source; `FeedFrameBaker`
    /// only downscaled *after* the graph, so ROI pull-back still ran every kernel at 4K.
    private static let maxWorkingWidth = CGFloat(FeedPresentPolicy.maxWorkingWidth)

    /// LUT is the displayed look. False colour / peaking / zebra read unmanaged
    /// camera codes, then composite over that look.
    ///
    /// `source` is encoded camera codes (NSNull). `display` is the Rec.709 / HLG
    /// identity with buffer attachments - used only when no LUT is armed.
    public static func apply(to source: CIImage, effects: MonitorImageEffects, display: CIImage? = nil)
        -> CIImage
    {
        applyProduct(to: source, effects: effects, display: display).image
    }

    /// Same graph as ``apply(to:effects:display:)``. `unmanagedBake` is true only
    /// when the output is a LUT cube product. Identity fallbacks stay managed -
    /// NSNull of Rec.709 HEVC is a black feed. False colour rides the overlay.
    public static func applyProduct(
        to source: CIImage, effects: MonitorImageEffects, display: CIImage? = nil
    ) -> (image: CIImage, unmanagedBake: Bool) {
        // Downscale FIRST. The 3D cubes are resolution-independent; peaking and zebra
        // *want* display resolution. `FeedFrameBaker.bake` composes any further drawable
        // fit on the already-small image, so the final on-screen size is unchanged.
        var measure = source
        var displayed = display
        let sourceWidth = source.extent.width
        if sourceWidth > maxWorkingWidth {
            let scale = maxWorkingWidth / sourceWidth
            let transform = CGAffineTransform(scaleX: scale, y: scale)
            measure = source.transformed(by: transform)
            displayed = display?.transformed(by: transform)
        }
        let input = unmanaged(measure)
        let extent = input.extent
        let hasLUT = effects.lutDimension >= 2 && !effects.lutRGBA.isEmpty
        var graded = input
        if hasLUT {
            let lut =
                applyLUT(to: input, dimension: effects.lutDimension, rgba: effects.lutRGBA) ?? input
            graded =
                effects.appliesSplitComparison
                ? split(lut, over: input, extent: extent, vertical: effects.splitVertical)
                : lut
        }

        // No cube: keep the caller's YUV→RGB attachments. Unmanaged NSNull is LUT-only -
        // Rec.709 / HLG identity through NSNull presents black on CIFeedView.
        var output = hasLUT ? graded : (displayed ?? measure)
        let cubeProduct = hasLUT
        if effects.falseColor {
            output = applyFalseColor(
                over: output, codes: input, extent: extent, effects: effects)
        }

        if effects.peaking {
            output = applyPeaking(
                over: output, source: input, extent: extent,
                color: effects.peakingColor, sense: effects.peakingSensitivity,
                gateScale: effects.peakingGateScale)
        }
        if effects.zebra {
            output = applyZebra(
                over: output, source: input, extent: extent,
                zebra: effects.zebraSpec,
                transfer: effects.transfer, clipByte: effects.clipByte)
        }
        if effects.desqueezeFactor > 1.001 {
            output = desqueeze(
                output, factor: effects.desqueezeFactor, horizontal: effects.desqueezeHorizontal)
        }
        return (output, cubeProduct)
    }

    /// Stripe / peaking paint only - alpha 0 where the identity picture should show through.
    /// Used for overlay-only native policies so the HEVC / VT layer is never remade.
    public static func assistOverlay(from source: CIImage, effects: MonitorImageEffects) -> CIImage {
        var measure = source
        let sourceWidth = source.extent.width
        if sourceWidth > maxWorkingWidth {
            let scale = maxWorkingWidth / sourceWidth
            measure = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let input = unmanaged(measure)
        let extent = input.extent
        var output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
            .cropped(to: extent)
        if effects.falseColor {
            output = applyFalseColor(
                over: output, codes: input, extent: extent, effects: effects)
        }
        if effects.peaking {
            output = applyPeaking(
                over: output, source: input, extent: extent,
                color: effects.peakingColor, sense: effects.peakingSensitivity,
                gateScale: effects.peakingGateScale)
        }
        if effects.zebra {
            output = applyZebra(
                over: output, source: input, extent: extent,
                zebra: effects.zebraSpec,
                transfer: effects.transfer, clipByte: effects.clipByte)
        }
        return output
    }

    /// Scale an overlay (often the 1440 working width) onto a full-resolution identity.
    /// Simulator has no HEVC layer, so the overlay is composited over the pixel-buffer picture.
    public static func place(_ overlay: CIImage, over base: CIImage) -> CIImage {
        let overlayExtent = overlay.extent
        let baseExtent = base.extent
        guard overlayExtent.width > 1, overlayExtent.height > 1,
            baseExtent.width > 1, baseExtent.height > 1
        else { return overlay.composited(over: base) }
        let scale = min(
            baseExtent.width / overlayExtent.width,
            baseExtent.height / overlayExtent.height)
        let scaled = overlay.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placedExtent = scaled.extent
        let placed = scaled.transformed(
            by: CGAffineTransform(
                translationX: baseExtent.midX - placedExtent.midX,
                y: baseExtent.midY - placedExtent.midY))
        return placed.composited(over: base.cropped(to: baseExtent))
    }

    /// Encoded camera codes - do not let Core Image sRGB-linearize the source signal before the cubes.
    /// the original renderer `LiveFrameProcessor` marks the same way (`options: [.colorSpace: NSNull()]`).
    private static func unmanaged(_ image: CIImage) -> CIImage {
        image.settingProperties(MonitorWorkingSpace.imageOptions)
    }

    /// Paint from pre-LUT camera codes, composited over the displayed look.
    /// Limits is holes-only (shadow / highlight warnings over the picture).
    /// CineStop / Video / IRE paint the full remap: WAVE grayscale in the gaps,
    /// not a hole onto camera colour. The first map warms asynchronously; exposure
    /// updates retain the last complete paint/mask pair until its replacement lands.
    private static func applyFalseColor(
        over base: CIImage, codes: CIImage, extent: CGRect, effects: MonitorImageEffects
    ) -> CIImage {
        guard
            let maps = effects.falseColorMaps,
            let paint = applyColorCube(
                to: codes, dimension: maps.dimension, rgba: maps.paint),
            let weight = applyColorCube(
                to: codes, dimension: maps.dimension, rgba: maps.weight)
        else { return base }
        return paint.cropped(to: extent).applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: base.cropped(to: extent),
                kCIInputMaskImageKey: weight.cropped(to: extent),
            ])
    }

    private static func applyLUT(to source: CIImage, dimension: Int, rgba: Data) -> CIImage? {
        applyColorCube(to: source, dimension: dimension, rgba: rgba)
    }

    private static func applyColorCube(to source: CIImage, dimension: Int, rgba: Data) -> CIImage? {
        // A fresh CIFilter per apply is graph description only - the cube Data is CoW and
        // the GPU cost lives in the render. The old shared filter + global NSLock made
        // every look serialize through one mutable `setValue`.
        guard
            let filter = CIFilter(
                name: "CIColorCube",
                parameters: [
                    "inputCubeDimension": dimension,
                    "inputCubeData": rgba,
                    kCIInputImageKey: source.clampedToExtent(),
                ])
        else { return nil }
        return filter.outputImage?.cropped(to: source.extent)
    }

    /// the original renderer 50/50 Log-vs-LUT: graded half composited over the clean source.
    /// Core Image y is up, so the operator's top half is the high-y half.
    private static func split(
        _ graded: CIImage, over source: CIImage, extent: CGRect, vertical: Bool
    ) -> CIImage {
        guard extent.width > 0, extent.height > 0 else { return graded }
        let half =
            vertical
            ? CGRect(x: extent.midX, y: extent.minY, width: extent.width / 2, height: extent.height)
            : CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2)
        return graded.cropped(to: half).composited(over: source.cropped(to: extent))
    }

    private static func desqueeze(_ image: CIImage, factor: Double, horizontal: Bool) -> CIImage {
        let e = image.extent
        let sx = horizontal ? factor : 1
        let sy = horizontal ? 1 : factor
        let scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        let s = scaled.extent
        let dx = e.midX - s.midX
        let dy = e.midY - s.midY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }

    // MARK: - Peaking (the original renderer fused kernel, filter-chain fallback)

    private static let fusedPeakingKernel: CIKernel? = makeFusedPeakingKernel()

    private static let fusedPeakingCheck: (matches: Bool, note: String) = {
        verifyAgainstChain()
    }()

    public static var fusedPeakingAvailable: Bool {
        fusedPeakingKernel != nil && fusedPeakingCheck.matches
    }

    public static var fusedPeakingNote: String { fusedPeakingCheck.note }

    private static func verifyAgainstChain() -> (Bool, String) {
        guard let kernel = fusedPeakingKernel else { return (false, "kernel did not compile") }
        let w = 96
        let h = 64
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                var value = 64
                if x % 7 == 3 { value = 210 }
                if y % 9 == 4 { value = 16 }
                for c in 0..<3 { bytes[(y * w + x) * 4 + c] = UInt8(value) }
            }
        }
        let source = CIImage(
            bitmapData: Data(bytes), bytesPerRow: w * 4, size: CGSize(width: w, height: h),
            format: .RGBA8, colorSpace: nil)
        let extent = source.extent
        let context = CIContext(options: [
            .workingFormat: CIFormat.RGBAf,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                ?? CGColorSpaceCreateDeviceRGB(),
            .cacheIntermediates: false,
        ])
        func rendered(_ image: CIImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * 4)
            context.render(
                image, toBitmap: &out, rowBytes: w * 4, bounds: extent, format: .BGRA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
            return out
        }
        let chain = rendered(
            applyPeakingFilterChain(
                over: source, source: source, extent: extent,
                color: .red, sense: .medium, gateScale: 1))
        let plain = rendered(source)
        let painted = zip(chain, plain).reduce(0) { $0 + (abs(Int($1.0) - Int($1.1)) > 2 ? 1 : 0) }
        guard painted > 0 else {
            return (false, "chain fallback - probe frame drew no peaking, so nothing was validated")
        }
        guard
            let fusedImage = applyFusedPeaking(
                kernel: kernel, over: source, source: source, extent: extent,
                color: .red, sense: .medium, gateScale: 1)
        else { return (false, "chain fallback - kernel apply returned nil") }
        let fused = rendered(fusedImage)
        var worst = 0
        var differing = 0
        for i in 0..<chain.count {
            let d = abs(Int(chain[i]) - Int(fused[i]))
            worst = max(worst, d)
            if d > 2 { differing += 1 }
        }
        guard worst <= 2 else {
            return (
                false,
                "chain fallback - worst \(worst)/255 over \(differing) channels (chain painted \(painted))"
            )
        }
        return (true, "fused (chain painted \(painted) channels, worst delta \(worst)/255)")
    }

    private static func makeFusedPeakingKernel() -> CIKernel? {
        CIKernel(
            source: """
                float robertsSquared(sampler s, vec2 p) {
                  float a = sample(s, samplerTransform(s, p)).r;
                  float b = sample(s, samplerTransform(s, p + vec2(1.0,  0.0))).r;
                  float c = sample(s, samplerTransform(s, p + vec2(0.0, -1.0))).r;
                  float d = sample(s, samplerTransform(s, p + vec2(1.0, -1.0))).r;
                  float d1 = d - a;
                  float d2 = c - b;
                  return d1 * d1 + d2 * d2;
                }

                kernel vec4 peakingMask(
                    sampler grey, sampler blurred,
                    float ratioScale, float gateGain, float gateBias,
                    float rampGain, float coreBias, float underBias,
                    vec2 lo, vec2 hi) {
                  vec2 p = destCoord();
                  float fine = robertsSquared(grey, p);
                  float coarse = robertsSquared(blurred, p);
                  float ratio = min(fine * ratioScale / max(coarse, 1e-9), 1.0);
                  float gate = clamp(coarse * gateGain + gateBias, 0.0, 1.0);
                  float core = clamp(ratio * rampGain + coreBias, 0.0, 1.0) * gate;
                  float under = clamp(ratio * rampGain + underBias, 0.0, 1.0) * gate;
                  float window = step(lo.x, p.x) * step(lo.y, p.y)
                      * (1.0 - step(hi.x, p.x)) * (1.0 - step(hi.y, p.y));
                  return vec4(core * window, under * window, 0.0, 1.0);
                }
                """)
    }

    public static func applyPeaking(
        over base: CIImage, source: CIImage, extent: CGRect,
        color: MonitorRGB, sense: MonitorPeakingSensitivity, gateScale: Double = 1,
        fusedWindowPolicy: MonitorPeakingFusedWindowPolicy = .extendedAnalysisWindow
    ) -> CIImage {
        if let kernel = fusedPeakingKernel, fusedPeakingCheck.matches,
            let fused = applyFusedPeaking(
                kernel: kernel, over: base, source: source, extent: extent,
                color: color, sense: sense, gateScale: gateScale,
                fusedWindowPolicy: fusedWindowPolicy)
        {
            return fused
        }
        return applyPeakingFilterChain(
            over: base, source: source, extent: extent,
            color: color, sense: sense, gateScale: gateScale)
    }

    private static func applyFusedPeaking(
        kernel: CIKernel, over base: CIImage, source: CIImage, extent: CGRect,
        color: MonitorRGB, sense: MonitorPeakingSensitivity, gateScale: Double,
        fusedWindowPolicy: MonitorPeakingFusedWindowPolicy = .extendedAnalysisWindow
    ) -> CIImage? {
        let cropped = extent.insetBy(dx: Peak.edgeInset, dy: Peak.edgeInset)
        if fusedWindowPolicy == .extendedAnalysisWindow {
            guard cropped.width > 8, cropped.height > 8 else { return nil }
        }
        let grey = greyscale(source).clampedToExtent()
        let blurred = grey.applyingFilter(
            "CIGaussianBlur", parameters: [kCIInputRadiusKey: Peak.reblurRadius])
        let gate = sense.noiseGate * gateScale
        let gateGain = 1.0 / max(gate * (1 - Peak.gateRampFloor), 1e-6)
        let rampGain = 1.0 / max(Peak.antialiasWidth * Peak.ratioScale, 1e-6)
        let threshold = sense.ratioThreshold
        guard
            let mask = kernel.apply(
                extent: cropped.insetBy(dx: -2, dy: -2),
                roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
                arguments: [
                    grey, blurred,
                    Peak.ratioScale, gateGain, -(gate * Peak.gateRampFloor) * gateGain,
                    rampGain, -(threshold * Peak.ratioScale) * rampGain,
                    -((threshold - Peak.antialiasWidth * Peak.underRampOffset) * Peak.ratioScale)
                        * rampGain,
                    CIVector(x: cropped.minX, y: cropped.minY),
                    CIVector(x: cropped.maxX, y: cropped.maxY),
                ])
        else { return nil }

        var coreMask = mask
        if Peak.maskClosingRadius > 0 {
            coreMask =
                mask
                .applyingFilter(
                    "CIMorphologyMaximum",
                    parameters: [kCIInputRadiusKey: Peak.maskClosingRadius]
                )
                .applyingFilter(
                    "CIMorphologyMinimum",
                    parameters: [kCIInputRadiusKey: Peak.maskClosingRadius]
                )
                .cropped(to: cropped)
        }
        let core = broadcast(.red, of: coreMask)
        let under = broadcast(.green, of: mask)
        return composite(over: base, coreMask: core, underMask: under, color: color, extent: extent)
    }

    private enum MaskChannel { case red, green }

    private static func broadcast(_ channel: MaskChannel, of image: CIImage) -> CIImage {
        let vector =
            channel == .red
            ? CIVector(x: 1, y: 0, z: 0, w: 0) : CIVector(x: 0, y: 1, z: 0, w: 0)
        return image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": vector,
                "inputGVector": vector,
                "inputBVector": vector,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    public static func applyPeakingFilterChain(
        over base: CIImage, source: CIImage, extent: CGRect,
        color: MonitorRGB, sense: MonitorPeakingSensitivity, gateScale: Double = 1
    ) -> CIImage {
        let grey = greyscale(source).clampedToExtent()
        let cropped = extent.insetBy(dx: Peak.edgeInset, dy: Peak.edgeInset)
        let fine = grey.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0]).cropped(
            to: cropped)
        let coarse =
            grey
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: Peak.reblurRadius])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
            .cropped(to: cropped)

        func scale(_ image: CIImage, by factor: Double, bias: Double = 0) -> CIImage {
            image.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: factor, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: factor, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
                ])
        }

        let ratio =
            (CIFilter(
                name: "CIDivideBlendMode",
                parameters: [
                    kCIInputImageKey: coarse,
                    kCIInputBackgroundImageKey: scale(fine, by: Peak.ratioScale),
                ])?.outputImage ?? coarse)
            .cropped(to: cropped)

        let gate = sense.noiseGate * gateScale
        let gateGain = 1.0 / max(gate * (1 - Peak.gateRampFloor), 1e-6)
        let gateMask = scale(coarse, by: gateGain, bias: -(gate * Peak.gateRampFloor) * gateGain)
            .applyingFilter("CIColorClamp")

        func ramp(from start: Double) -> CIImage {
            let gain = 1.0 / max(Peak.antialiasWidth * Peak.ratioScale, 1e-6)
            let masked = scale(ratio, by: gain, bias: -(start * Peak.ratioScale) * gain)
                .applyingFilter("CIColorClamp")
            return
                (CIFilter(
                    name: "CIMultiplyCompositing",
                    parameters: [kCIInputImageKey: masked, kCIInputBackgroundImageKey: gateMask]
                )?.outputImage ?? masked)
                .cropped(to: cropped)
        }

        var coreMask = ramp(from: sense.ratioThreshold)
        if Peak.maskClosingRadius > 0 {
            coreMask =
                coreMask
                .applyingFilter(
                    "CIMorphologyMaximum", parameters: [kCIInputRadiusKey: Peak.maskClosingRadius]
                )
                .applyingFilter(
                    "CIMorphologyMinimum", parameters: [kCIInputRadiusKey: Peak.maskClosingRadius]
                )
                .cropped(to: cropped)
        }
        let underMask = ramp(
            from: sense.ratioThreshold - Peak.antialiasWidth * Peak.underRampOffset)
        return composite(
            over: base, coreMask: coreMask, underMask: underMask, color: color, extent: extent)
    }

    private static func greyscale(_ source: CIImage) -> CIImage {
        let third = 1.0 / 3.0
        return source.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputGVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputBVector": CIVector(x: third, y: third, z: third, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }

    private static func composite(
        over base: CIImage, coreMask: CIImage, underMask: CIImage, color: MonitorRGB,
        extent: CGRect
    ) -> CIImage {
        let dark = CIImage(
            color: CIColor(red: Peak.underColor.red, green: Peak.underColor.green, blue: Peak.underColor.blue)
        )
        .cropped(to: extent)
        let rgb = color.rgb
        let tint = CIImage(color: CIColor(red: rgb.0, green: rgb.1, blue: rgb.2)).cropped(
            to: extent)
        let withUnder =
            (CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: dark, kCIInputBackgroundImageKey: base,
                    kCIInputMaskImageKey: underMask,
                ])?.outputImage ?? base)
            .cropped(to: extent)
        return
            (CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: tint, kCIInputBackgroundImageKey: withUnder,
                    kCIInputMaskImageKey: coreMask,
                ])?.outputImage ?? withUnder)
            .cropped(to: extent)
    }

    // MARK: - Zebra (`ScopeDisplayScale.signalNative` thresholds)

    /// The source's encoded codes against the shared zones for its curve and live ceiling
    /// (``MonitorCodeZebraSpec/init(_:transfer:clipByte:)``). Unit is editor-only: both zones
    /// read the monitor percentage here.
    public static func applyZebra(
        over base: CIImage, source: CIImage, extent: CGRect,
        zebra: MonitorZebraSpec, transfer: MonitorTransfer, clipByte: Int
    ) -> CIImage {
        applyResolvedZebra(
            over: base, source: source, extent: extent,
            zebra: MonitorCodeZebraSpec(zebra, transfer: transfer, clipByte: clipByte))
    }

    /// Render already calibrated code-value zones without inventing a source transfer.
    /// Existing IRE-based entry points keep their original default graph.
    public static func applyResolvedZebra(
        over base: CIImage, source: CIImage, extent: CGRect, zebra: MonitorCodeZebraSpec
    ) -> CIImage {
        let luma = source.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
        let highlightSource = zebra.maskPolicy.highlightMeasure == .rec709Luma
            ? luma : source.applyingFilter("CIMaximumComponent")
        var output = base
        if let threshold = zebra.thresholds.highlight {
            let rgb = zebra.highlightColor.rgb
            output = blendStripedZebra(
                over: output,
                mask: thresholdMask(highlightSource, above: threshold,
                    bias: zebra.maskPolicy.rampBias),
                color: CIColor(red: rgb.0, green: rgb.1, blue: rgb.2), extent: extent)
        }
        if let lower = zebra.thresholds.midtoneLower,
            let upper = zebra.thresholds.midtoneUpper {
            let rgb = zebra.midtoneColor.rgb
            output = blendStripedZebra(
                over: output,
                mask: bandMask(luma, lower: lower, upper: upper,
                    bias: zebra.maskPolicy.rampBias),
                color: CIColor(red: rgb.0, green: rgb.1, blue: rgb.2), extent: extent)
        }
        return output
    }

    private static func thresholdMask(_ luma: CIImage, above threshold: Double, bias: Double = 1) -> CIImage {
        let gain = 40.0
        // Bias +1 so luma == threshold paints (`ire100 >= highlight`), matching LiveZebra.
        return luma.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(
                    x: -threshold * gain + bias, y: -threshold * gain + bias, z: -threshold * gain + bias,
                    w: 1),
            ]
        ).applyingFilter("CIColorClamp")
    }

    private static func bandMask(_ luma: CIImage, lower: Double, upper: Double, bias: Double) -> CIImage {
        let low = thresholdMask(luma, above: lower, bias: bias)
        let high = luma.applyingFilter(
            "CIColorMatrix",
            parameters: {
                let gain = 40.0
                return [
                    "inputRVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: -gain, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(
                        x: upper * gain + bias, y: upper * gain + bias, z: upper * gain + bias, w: 1),
                ]
            }()
        ).applyingFilter("CIColorClamp")
        return low.applyingFilter(
            "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: high])
    }

    private static func blendStripedZebra(
        over base: CIImage, mask: CIImage, color: CIColor, extent: CGRect
    ) -> CIImage {
        let stripes =
            (CIFilter(
                name: "CIStripesGenerator",
                parameters: [
                    "inputColor0": CIColor(red: 0, green: 0, blue: 0),
                    "inputColor1": CIColor(red: 1, green: 1, blue: 1),
                    "inputWidth": 5.0,
                    "inputSharpness": 1.0,
                    kCIInputCenterKey: CIVector(x: 0, y: 0),
                ])?.outputImage ?? CIImage(color: CIColor(red: 1, green: 1, blue: 1)))
            .transformed(by: CGAffineTransform(rotationAngle: CGFloat.pi / 4))
            .cropped(to: extent)
        let stripedMask = stripes.applyingFilter(
            "CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        let tint = CIImage(color: color).cropped(to: extent)
        return
            (CIFilter(
                name: "CIBlendWithMask",
                parameters: [
                    kCIInputImageKey: tint,
                    kCIInputBackgroundImageKey: base,
                    kCIInputMaskImageKey: stripedMask,
                ])?.outputImage ?? base)
            .cropped(to: extent)
    }
}

#endif
