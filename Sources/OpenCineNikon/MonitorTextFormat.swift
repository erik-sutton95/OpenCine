import Foundation

/// Compact, wireframe-style display formatting for the live-view monitor.
///
/// Camera-native values (raw pixel dimensions, fractional frame rates) are rendered as the
/// short operator-facing labels used in the top status bar and picker menus, e.g.
/// `6K · 24p` rather than `6048 × 3402`.
public enum MonitorTextFormat {
    /// Formats a resolution + frame rate as a compact label such as `6K · 24p`. The resolution
    /// class (`8K`/`6K`/`4K`) comes from the pixel width; smaller widths fall back to the raw
    /// pixel count so the readout never inflates. The frame rate rounds to an integer `p` value;
    /// an unknown rate (zero or less) is left out rather than shown as `0p`. Kotlin twin:
    /// `Android/nikon` `MonitorTextFormat`, both read `Fixtures/nikon-monitor-text.tsv`.
    public static func resolutionLabel(
        pixelWidth: Int,
        pixelHeight: Int,
        frameRate: Double
    ) -> String {
        let resolution = resolutionClass(pixelWidth: pixelWidth)
        let rate = frameRate.isFinite ? Int(frameRate.rounded()) : 0
        return rate > 0 ? "\(resolution) · \(rate)p" : resolution
    }

    /// Formats a PTP camera-property `"WxH"` resolution string (`"6048x3402"`) + integer frame
    /// rate as a compact label such as `6K · 25p`. Returns `fallback` when the property is missing
    /// or unparsable so the readout never blanks out.
    public static func resolutionLabel(
        fromProperty property: String?,
        frameRate: Int,
        fallback: String = ""
    ) -> String {
        guard let property else { return fallback }
        let parts = property.split(separator: "x")
        guard parts.count == 2,
            let width = Int(parts[0]),
            let height = Int(parts[1])
        else {
            return fallback
        }
        return resolutionLabel(pixelWidth: width, pixelHeight: height, frameRate: Double(frameRate))
    }

    /// Whether a codec label names a RAW format (R3D NE, N-RAW, ProRes RAW HQ). Used to gate
    /// controls that RAW disallows — e.g. electronic VR, which the ZR can't apply to a RAW stream.
    /// Substring match on the uppercased label; works on both the raw camera string and the
    /// already-shortened `codecShortLabel` output.
    public static func isRawCodec(_ codec: String) -> Bool {
        let upper = codec.uppercased()
        return upper.contains("RAW") || upper.contains("R3D")
    }

    /// Collapses a verbose camera-reported codec name to its short family label: firmware reports
    /// e.g. `"R3D NE 10-bit R3D"` (the format repeated as a bit-depth qualifier) — this trims the
    /// redundant suffix to `"R3D NE"`. Already-short names (`"ProRes RAW HQ"`) pass through.
    public static func codecShortLabel(_ codec: String) -> String {
        let stripped = codec.trimmingCharacters(in: .whitespaces)
        // Drop a trailing `N-bit <name>` qualifier where `<name>` repeats the leading token.
        // "R3D NE 10-bit R3D" → first token group "R3D NE" + redundant "10-bit R3D".
        if let start = BitDepthQualifier.start(in: stripped, requiresTrailingName: true) {
            return String(stripped[..<start]).trimmingCharacters(in: .whitespaces)
        }
        return stripped
    }

    /// Abbreviates a codec name for tight readouts such as the top-bar pill: `ProRes` collapses
    /// to `PR` and a trailing bit-depth qualifier is dropped from H.26x names. Short names
    /// (`R3D NE`, `N-RAW`) pass through unchanged.
    public static func codecCompactLabel(_ codec: String) -> String {
        var label = codecShortLabel(codec).replacingOccurrences(of: "ProRes", with: "PR")
        if label.hasPrefix("H.26"),
            let start = BitDepthQualifier.start(in: label, requiresTrailingName: false)
        {
            label = String(label[..<start])
        }
        return label.trimmingCharacters(in: .whitespaces)
    }

    /// Maps a pixel width to its marketing resolution class, or the raw width when no class fits.
    public static func resolutionClass(pixelWidth: Int) -> String {
        switch pixelWidth {
        case 7680...: "8K"
        case 5000..<7680: "6K"
        case 3500..<5000: "4K"
        default: "\(pixelWidth)"
        }
    }
}

/// The codec readouts are formatted on every live surface evaluation, which a running timecode
/// repeats once per live view frame. A Regex literal is parsed again on each call (build 304 CPU
/// report, 2026-10-25), so the bit-depth qualifier is found by scanning. Strings with newlines or
/// non-ASCII characters keep the original Regex, whose Unicode classes this scan does not model.
private enum BitDepthQualifier {
    /// The start of the first `\s+\d+-bit` run that is followed by `\s+.+` to the end
    /// (`requiresTrailingName`) or by the end itself, as `firstMatch` reports it.
    static func start(in text: String, requiresTrailingName: Bool) -> String.Index? {
        guard text.contains("-bit") else { return nil }
        guard text.allSatisfy({ $0.isASCII && !$0.isNewline }) else {
            let match = requiresTrailingName
                ? text.firstMatch(of: #/\s+\d+-bit\s+.+$/#)?.range
                : text.firstMatch(of: #/\s+\d+-bit$/#)?.range
            return match?.lowerBound
        }
        let bytes = Array(text.utf8)
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }
        func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
        let marker = Array("-bit".utf8)
        var index = 0
        while index < bytes.count {
            // The leftmost match starts at the first space of a space run.
            guard isSpace(bytes[index]), index == 0 || !isSpace(bytes[index - 1]) else {
                index += 1
                continue
            }
            var cursor = index
            while cursor < bytes.count, isSpace(bytes[cursor]) { cursor += 1 }
            let digits = cursor
            while cursor < bytes.count, isDigit(bytes[cursor]) { cursor += 1 }
            if cursor > digits, cursor + marker.count <= bytes.count,
                Array(bytes[cursor..<cursor + marker.count]) == marker
            {
                let after = cursor + marker.count
                if requiresTrailingName {
                    var name = after
                    while name < bytes.count, isSpace(bytes[name]) { name += 1 }
                    // `\s+` needs one space and `.+` one more character; a space run that
                    // reaches the end can give its last space to `.+`.
                    let spaces = name - after
                    let rest = bytes.count - name
                    if spaces >= 1 && (rest >= 1 || spaces >= 2) {
                        return text.utf8.index(text.startIndex, offsetBy: index)
                    }
                } else if after == bytes.count {
                    return text.utf8.index(text.startIndex, offsetBy: index)
                }
            }
            index += 1
        }
        return nil
    }
}

extension MonitorTextFormat {
    /// The remaining-shots readout: the count below a thousand, then thousands with one decimal
    /// (`6.7k`, `20.2k`) and no trailing zero (`12k`), whole thousands from 100k. Rounded down so
    /// the header never promises a frame the card cannot hold (hardware pass 1.2). The header
    /// pairs it with a picture glyph instead of a "SHOTS" word.
    public static func shotsRemainingCompactLabel(_ count: Int) -> String {
        let count = max(0, count)
        if count < 1000 { return "\(count)" }
        let tenths = count / 100 % 10
        if count < 100_000, tenths != 0 { return "\(count / 1000).\(tenths)k" }
        return "\(count / 1000)k"
    }

    /// The complete count the compact readout stands for, as VoiceOver and TalkBack speak it.
    public static func shotsRemainingAccessibilityLabel(_ count: Int) -> String {
        "\(max(0, count)) shots remaining"
    }
}
