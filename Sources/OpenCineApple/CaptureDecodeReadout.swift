#if canImport(CoreImage) && canImport(CoreVideo) && canImport(IOSurface)
    import CoreGraphics
    import CoreImage
    import CoreVideo
    import Foundation
    import IOSurface

    /// DIAGNOSTIC (HDMI green cast hunt), not for merge: which colour space Core Image actually
    /// decodes a live frame with, read off the buffer at the moment it becomes a `CIImage`.
    ///
    /// The simulator and the iPad disagree on the same code (identity in one, a Rec.709-to-sRGB
    /// lift in the other), so the answer has to come from the device: the CoreVideo attachments,
    /// whatever colour the IOSurface itself carries, the colour space `CIImage(cvPixelBuffer:)`
    /// chose, and the context's working and output spaces. Metadata only, at most once per
    /// `interval`; no pixel is read.
    public final class CaptureDecodeReadout: @unchecked Sendable {
        /// Which decode ran for the frame described.
        public enum Path: String, Sendable {
            case hdmiRender = "HDMI render"
            case wifiHardware = "Wi-Fi hardware"
            case wifiHardwareDenoise = "Wi-Fi hardware+denoise"
            case wifiImageIO = "Wi-Fi ImageIO fallback"
        }

        private let lock = NSLock()
        private let interval: TimeInterval
        private var lastRecorded: TimeInterval?
        private var latest: String?

        public init(interval: TimeInterval = 1) { self.interval = interval }

        /// The latest description, nil until the first frame.
        public var summary: String? { lock.withLock { latest } }

        /// Runs `describe` and keeps its result, at most once per `interval`.
        public func recordIfDue(
            now: TimeInterval = ProcessInfo.processInfo.systemUptime, _ describe: () -> String
        ) {
            let due = lock.withLock {
                if let last = lastRecorded, now - last < interval { return false }
                lastRecorded = now
                return true
            }
            guard due else { return }
            let text = describe()
            lock.withLock { latest = text }
        }

        /// Two lines for a buffer handed to `CIImage(cvPixelBuffer:)`:
        /// `HDMI render · 420v · M 709 P 709 T 709 G - · ICC no`
        /// `IOSurface cs none · CI ITUR_709 · ctx work ExtendedLinearSRGB out SRGB`
        public static func describe(
            _ path: Path, pixelBuffer: CVPixelBuffer, image: CIImage, context: CIContext,
            rendered: CGImage?
        ) -> String {
            func attachment(_ key: CFString) -> CFTypeRef? {
                CVBufferCopyAttachment(pixelBuffer, key, nil)
            }
            func tag(_ key: CFString) -> String { attachment(key).map(describe) ?? "-" }
            var first =
                "\(path.rawValue) · \(fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer)))"
                + " · M \(tag(kCVImageBufferYCbCrMatrixKey))"
                + " P \(tag(kCVImageBufferColorPrimariesKey))"
                + " T \(tag(kCVImageBufferTransferFunctionKey))"
                + " G \(tag(kCVImageBufferGammaLevelKey))"
                + " · ICC \(attachment(kCVImageBufferICCProfileKey).map(describe) ?? "no")"
            if let guessed = attachment("ColorInfoGuessedBy" as CFString) {
                first += " · guess \(describe(guessed))"
            }
            let second =
                "IOSurface \(surfaceColour(pixelBuffer)) · CI \(label(image.colorSpace))"
                + " · ctx work \(label(context.workingColorSpace))"
                + " out \(label(rendered?.colorSpace))"
            return first + "\n" + second
        }

        /// One line for the ImageIO fallback: the decoded JPEG's own colour space and the one the
        /// display-prepared copy ends up in.
        public static func describe(
            _ path: Path, decoded: CGImage?, prepared: CGImage?
        ) -> String {
            "\(path.rawValue) · JPEG cs \(label(decoded?.colorSpace))"
                + " · prepared \(label(prepared?.colorSpace))"
        }

        // MARK: - Short names

        static func fourCC(_ format: OSType) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8((format >> $0) & 0xFF) }
            let text = String(decoding: bytes, as: UTF8.self)
            return bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? text : String(format)
        }

        /// The CoreVideo constants' raw values, shortened; anything unknown passes through raw.
        static func shortName(_ raw: String) -> String {
            switch raw {
            case "ITU_R_709_2": "709"
            case "ITU_R_601_4": "601"
            case "ITU_R_2020": "2020"
            case "ITU_R_2100_HLG": "HLG"
            case "SMPTE_ST_2084_PQ", "SMPTE_ST_2084": "PQ"
            case "IEC_sRGB": "sRGB"
            case "SMPTE_240M_1995": "240M"
            case "EBU_3213": "EBU"
            case "P3_D65": "P3"
            default: raw
            }
        }

        /// A colour space by name, or by the ICC profile description its debug text carries
        /// (ICC-based spaces have no name).
        static func label(_ space: CGColorSpace?) -> String {
            guard let space else { return "nil" }
            if let name = space.name as String? {
                return name.replacingOccurrences(of: "kCGColorSpace", with: "")
            }
            // "<CGColorSpace 0x...> (kCGColorSpaceICCBased; kCGColorSpaceModelRGB; sRGB IEC61966-2.1)"
            let text = CFCopyDescription(space) as String
            if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"),
                open < close,
                let last = text[text.index(after: open)..<close].split(separator: ";").last
            {
                return "ICC '\(last.trimmingCharacters(in: .whitespaces))'"
            }
            return "unnamed"
        }

        /// Any CF value an attachment or IOSurface property may hold, as short text.
        static func describe(_ value: CFTypeRef) -> String {
            let type = CFGetTypeID(value)
            if type == CFStringGetTypeID(), let text = value as? String { return shortName(text) }
            if type == CFNumberGetTypeID(), let number = value as? NSNumber {
                return number.stringValue
            }
            if type == CFBooleanGetTypeID(), let flag = value as? Bool { return flag ? "yes" : "no" }
            if type == CFDataGetTypeID(), let data = value as? Data {
                let space = CGColorSpace(iccData: data as CFData)
                return space.map { "\(label($0)) \(data.count)B" } ?? "data \(data.count)B"
            }
            if type == CGColorSpace.typeID {
                // SAFETY: the type ID check above makes this cast exact.
                return label(unsafeDowncast(value, to: CGColorSpace.self))
            }
            if type == CFDictionaryGetTypeID(), let dictionary = value as? [String: Any] {
                let colour = colourEntries(dictionary)
                return colour.isEmpty ? "{\(dictionary.count) keys}" : "{\(colour.joined(separator: ", "))}"
            }
            return String(describing: value)
        }

        private static let colourWords = [
            "color", "colour", "gamma", "transfer", "icc", "matrix", "primaries",
        ]

        static func isColourKey(_ key: String) -> Bool {
            let lowered = key.lowercased()
            return colourWords.contains { lowered.contains($0) }
        }

        private static func shortKey(_ key: String) -> String {
            key.replacingOccurrences(of: "IOSurface", with: "")
                .replacingOccurrences(of: "CVImageBuffer", with: "")
        }

        /// `key=value` for each colour-bearing entry, and for colour entries one dictionary deep.
        private static func colourEntries(_ dictionary: [String: Any]) -> [String] {
            var entries: [String] = []
            for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
                let object = value as AnyObject
                if isColourKey(key) {
                    entries.append("\(shortKey(key))=\(describe(object))")
                } else if let nested = value as? [String: Any] {
                    for (inner, innerValue) in nested.sorted(by: { $0.key < $1.key })
                    where isColourKey(inner) {
                        entries.append(
                            "\(shortKey(key)).\(shortKey(inner))=\(describe(innerValue as AnyObject))")
                    }
                }
            }
            return entries
        }

        /// `no` when the buffer has no IOSurface, else the surface's `IOSurfaceColorSpace` and any
        /// other colour-bearing surface property.
        static func surfaceColour(_ pixelBuffer: CVPixelBuffer) -> String {
            guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
                return "no"
            }
            let key = "IOSurfaceColorSpace"
            var text = "cs " + (IOSurfaceCopyValue(surface, key as CFString).map(describe) ?? "none")
            if var all = IOSurfaceCopyAllValues(surface) as? [String: Any] {
                all[key] = nil
                let others = colourEntries(all)
                text += others.isEmpty ? " (no other colour keys)" : " " + others.joined(separator: " ")
            }
            return text
        }
    }
#endif
