#if canImport(CoreVideo)
    import CoreVideo
    import Foundation

    /// DIAGNOSTIC (HDMI green cast hunt): the code values a captured YCbCr frame actually holds.
    ///
    /// The claims a frame carries (matrix, range in the FourCC, transfer) say how it should decode;
    /// these numbers say what is in it. Three field questions each have a signature here:
    ///
    /// - Range: a video-range container (`420v`, `2vuy`, `yuvs`) holding full-range data shows luma
    ///   below 16 or above 235 (decoded, it crushes and clips). A full-range container holding
    ///   video-range data keeps its luma inside 16...235 (decoded, it looks lifted and flat).
    /// - Neutral bias: the darkest tenth of the picture is near neutral on a real scene, so its mean
    ///   Cb/Cr far from 128 means the signal itself is tinted before any decode or look.
    /// - Tone: a log signal spends almost no codes near black or white (a narrow luma spread); a
    ///   display-referred (Rec.709) one reaches both ends.
    struct CaptureSignalLevels: Equatable, Sendable {
        /// The 1st and 99th percentile of the sampled 8-bit luma codes.
        var lumaLow: Int
        var lumaHigh: Int
        /// Fraction of sampled luma codes below 16 and above 235.
        var belowBlack: Double
        var aboveWhite: Double
        /// Mean 8-bit Cb and Cr of the samples whose luma is in the darkest tenth.
        var darkCb: Double
        var darkCr: Double
        /// Mean Cb and Cr over every sample.
        var meanCb: Double
        var meanCr: Double

        /// One readout line: `Y 4-250 <16 3.1% >235 1.2% dark Cb/Cr 127/129 mean 126/131`.
        var summary: String {
            func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }
            return "Y \(lumaLow)-\(lumaHigh) <16 \(percent(belowBlack)) >235 \(percent(aboveWhite))"
                + " dark Cb/Cr \(Int(darkCb.rounded()))/\(Int(darkCr.rounded()))"
                + " mean \(Int(meanCb.rounded()))/\(Int(meanCr.rounded()))"
        }

        /// The layouts this reads; anything else (10-bit, RGB) reads nil.
        private enum Layout {
            case biplanar
            /// 4:2:2 interleaved, with the byte offsets of Y0, Cb, Y1, Cr in each 4-byte group.
            case packed(y0: Int, cb: Int, y1: Int, cr: Int)
        }

        private static func layout(of format: OSType) -> Layout? {
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                .biplanar
            case kCVPixelFormatType_422YpCbCr8: .packed(y0: 1, cb: 0, y1: 3, cr: 2)
            case kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_422YpCbCr8FullRange:
                .packed(y0: 0, cb: 1, y1: 2, cr: 3)
            default: nil
            }
        }

        /// Whether `format` is a full-range YCbCr layout by its own definition.
        static func isFullRange(_ format: OSType) -> Bool {
            format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || format == kCVPixelFormatType_422YpCbCr8FullRange
        }

        /// Samples every `stride`th pixel on every `stride`th row (chroma at the co-sited sample).
        static func measure(_ pixelBuffer: CVPixelBuffer, stride: Int = 8) -> CaptureSignalLevels? {
            guard let layout = layout(of: CVPixelBufferGetPixelFormatType(pixelBuffer)) else {
                return nil
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var samples: [(y: UInt8, cb: UInt8, cr: UInt8)] = []
            samples.reserveCapacity((width / stride + 1) * (height / stride + 1))
            switch layout {
            case .biplanar:
                guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
                    let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
                else { return nil }
                let lumaRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let chromaRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                let y = luma.assumingMemoryBound(to: UInt8.self)
                let c = chroma.assumingMemoryBound(to: UInt8.self)
                for row in Swift.stride(from: 0, to: height, by: stride) {
                    for column in Swift.stride(from: 0, to: width, by: stride) {
                        let pair = (row / 2) * chromaRow + (column / 2) * 2
                        samples.append((y[row * lumaRow + column], c[pair], c[pair + 1]))
                    }
                }
            case .packed(let y0, let cb, let y1, let cr):
                guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
                let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for row in Swift.stride(from: 0, to: height, by: stride) {
                    for column in Swift.stride(from: 0, to: width, by: stride) {
                        let group = row * bytesPerRow + (column / 2) * 4
                        let luma = p[group + (column % 2 == 0 ? y0 : y1)]
                        samples.append((luma, p[group + cb], p[group + cr]))
                    }
                }
            }
            return summarize(samples)
        }

        static func summarize(_ samples: [(y: UInt8, cb: UInt8, cr: UInt8)])
            -> CaptureSignalLevels?
        {
            guard !samples.isEmpty else { return nil }
            let sorted = samples.sorted { $0.y < $1.y }
            let count = Double(sorted.count)
            func percentile(_ fraction: Double) -> Int {
                Int(sorted[min(sorted.count - 1, Int(count * fraction))].y)
            }
            let dark = sorted.prefix(max(1, sorted.count / 10))
            func mean(_ values: some Collection<UInt8>) -> Double {
                values.reduce(0.0) { $0 + Double($1) } / Double(max(1, values.count))
            }
            return CaptureSignalLevels(
                lumaLow: percentile(0.01), lumaHigh: percentile(0.99),
                belowBlack: Double(sorted.filter { $0.y < 16 }.count) / count,
                aboveWhite: Double(sorted.filter { $0.y > 235 }.count) / count,
                darkCb: mean(dark.map(\.cb)), darkCr: mean(dark.map(\.cr)),
                meanCb: mean(samples.map(\.cb)), meanCr: mean(samples.map(\.cr)))
        }
    }
#endif
