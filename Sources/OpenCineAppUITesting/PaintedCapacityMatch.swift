import CoreGraphics
import Foundation

/// One OCR token painted inside a control, in viewport coordinates.
public struct PaintedCapacityToken: Equatable, Sendable {
    public let value: String
    public let frame: CGRect

    public init(value: String, frame: CGRect) {
        self.value = value
        self.frame = frame
    }
}

/// Finds the storage capacity Vision read from a painted control. The written value may arrive as
/// one token (`115GB`), as a spaced token (`115 GB`), or as separate number and unit tokens.
public enum PaintedCapacityMatch {
    /// The number and unit of a capacity label, accepting both compact and spaced forms.
    public static func parts(_ expected: String) -> (number: String, unit: String)? {
        let pattern = #"\A([0-9][0-9.,]*)\s*([A-Za-z]+)\z"#
        guard let range = expected.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let text = String(expected[range])
        guard let unitStart = text.firstIndex(where: { $0.isLetter }) else { return nil }
        return (String(text[..<unitStart]).trimmingCharacters(in: .whitespaces),
                String(text[unitStart...]))
    }

    /// The painted ink for `expected`, or nil when Vision did not read it inside the control.
    public static func frame(expected: String, tokens: [PaintedCapacityToken],
        control: CGRect, viewport: CGRect) -> CGRect? {
        let contained = tokens.filter {
            control.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                && viewport.contains($0.frame)
        }
        if let complete = contained.first(where: { $0.value == expected }) {
            return complete.frame
        }
        guard let (number, unit) = parts(expected) else { return nil }
        let compact = number + unit
        if contained.count == 1, let joined = contained.first,
            joined.value.replacingOccurrences(of: " ", with: "") == compact,
            control.contains(joined.frame) {
            return joined.frame
        }
        let fragments = [number, unit].compactMap { part -> PaintedCapacityToken? in
            let matches = contained.filter { $0.value == part }
            return matches.count == 1 ? matches[0] : nil
        }
        guard contained.count == 2, fragments.count == 2,
            fragments[0].frame.midX < fragments[1].frame.midX,
            max(fragments[0].frame.minY, fragments[1].frame.minY)
                < min(fragments[0].frame.maxY, fragments[1].frame.maxY) else { return nil }
        let ink = fragments[0].frame.union(fragments[1].frame)
        guard control.contains(ink), viewport.contains(ink) else { return nil }
        return ink
    }
}
