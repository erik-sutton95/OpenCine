import Foundation

extension CubeLUT {
    /// Largest `.cube` an import reads at a trust boundary.
    public static let maximumImportBytes = 16 * 1024 * 1024

    /// Float exports write lattice points such as `1.000001` (official RED IPP2 presets), so the
    /// gate is a little wider than `0...1`; packing clamps. Clearly broken tables still fail.
    public static let importableSampleRange: ClosedRange<Float> = -0.05...1.05

    /// A `.cube` arriving at an import trust boundary (the Android LUT library): bounded size,
    /// strict UTF-8, a single `LUT_3D_SIZE`, finite samples inside [importableSampleRange], then
    /// the shared parser. Nil means the bytes must not be stored. Moved from OpenZCine's Android
    /// facade so every app's import runs the same rule.
    public static func validatedImport(_ bytes: [UInt8]) -> CubeLUT? {
        guard bytes.count <= maximumImportBytes, let text = String(bytes: bytes, encoding: .utf8),
            hasStrictImportBody(text)
        else { return nil }
        return try? parse(text)
    }

    private static func hasStrictImportBody(_ text: String) -> Bool {
        var foundSize = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") {
                guard !foundSize else { return false }
                foundSize = true
                continue
            }
            guard let first = line.first,
                ("0"..."9").contains(first) || first == "+" || first == "-" || first == "."
            else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let red = Float(fields[0]), let green = Float(fields[1]),
                let blue = Float(fields[2])
            else { continue }
            guard [red, green, blue].allSatisfy({ $0.isFinite && importableSampleRange.contains($0) })
            else { return false }
        }
        return true
    }
}
