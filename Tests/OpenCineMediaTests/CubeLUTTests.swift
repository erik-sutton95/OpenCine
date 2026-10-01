import Testing

@testable import OpenCineMedia

@Suite struct CubeLUTTests {
    @Test(arguments: [
        (
            "LUT_3D_SIZE 2\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 2.0 2.0 2.0\n0.0 0.0 0.0\n1.0 1.0 1.0\n",
            CubeLUTParseError.unsupportedDomain
        ),
        ("0 0 0\n1 1 1\n", .missingSize),
        ("LUT_3D_SIZE 2\n0 0 0\n1 1 1\n", .sampleCountMismatch(expected: 24, found: 6)),
        ("LUT_3D_SIZE 1\n0 0 0\n", .unsupportedSize(1)),
        ("LUT_3D_SIZE 66\n0 0 0\n", .unsupportedSize(66)),
        // Absurd sizes are rejected before the lattice is allocated.
        ("LUT_3D_SIZE 1000\n0 0 0\n", .unsupportedSize(1000)),
        // Resolve's default 65 is a supported size; only the body is short.
        ("LUT_3D_SIZE\t65\n0 0 0\n", .sampleCountMismatch(expected: 65 * 65 * 65 * 3, found: 3)),
    ])
    func rejectsMalformedCube(text: String, error: CubeLUTParseError) {
        #expect(throws: error) {
            try CubeLUT.parse(text)
        }
    }

    @Test func colorCubeDownsamplesSize65To64() {
        let n = 65
        let denom = Float(n - 1)
        var rgb = [Float]()
        rgb.reserveCapacity(n * n * n * 3)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    rgb.append(Float(r) / denom)
                    rgb.append(Float(g) / denom)
                    rgb.append(Float(b) / denom)
                }
            }
        }
        #expect(CubeLUT.supportedSizeRange.contains(65))
        let lut = CubeLUT(size: n, rgb: rgb)
        let gpu = lut.colorCube
        #expect(gpu.size == CubeLUT.colorCubeMaxDimension)
        #expect(gpu.rgb.count == 64 * 64 * 64 * 3)
        let mid = gpu.map(red: 0.5, green: 0.5, blue: 0.5)
        #expect(abs(mid.red - 0.5) < 0.02)
        #expect(abs(mid.green - 0.5) < 0.02)
        #expect(abs(mid.blue - 0.5) < 0.02)
        #expect(
            CubeLUT(size: 33, rgb: Array(repeating: 0, count: 33 * 33 * 33 * 3)).colorCube.size
                == 33)
    }

    @Test func parsesACRLFAuthoredCube() throws {
        let text =
            "# a comment\r\n"
            + "TITLE \"demo\"\r\n"
            + "LUT_3D_SIZE 2\r\n"
            + "DOMAIN_MIN 0.0 0.0 0.0\r\n"
            + "DOMAIN_MAX 1.0 1.0 1.0\r\n"
            + "0 0 0\r\n1 0 0\r\n0 1 0\r\n1 1 0\r\n"
            + "0 0 1\r\n1 0 1\r\n0 1 1\r\n1 1 1\r\n"
        let lut = try CubeLUT.parse(text)
        #expect(lut.size == 2)
        #expect(lut.rgb.count == 2 * 2 * 2 * 3)
        #expect(Array(lut.rgb.prefix(3)) == [0, 0, 0])
        #expect(Array(lut.rgb[3..<6]) == [1, 0, 0])
        #expect(Array(lut.rgb.suffix(3)) == [1, 1, 1])
    }

    @Test func rgbaComponentsInsertAlpha() throws {
        let lut = try CubeLUT.parse(
            """
            LUT_3D_SIZE 2
            0 0 0
            1 0 0
            0 1 0
            1 1 0
            0 0 1
            1 0 1
            0 1 1
            1 1 1
            """
        )
        let rgba = lut.rgbaComponents
        #expect(rgba.count == 2 * 2 * 2 * 4)
        #expect(rgba[3] == 1)
        #expect(Array(rgba.prefix(4)) == [0, 0, 0, 1])
    }

    @Test func builtInMonoIsGreyscale() {
        let cube = BuiltInLook.mono.cube(size: 5)
        #expect(cube.size == 5)
        let mid = cube.map(red: 1, green: 0, blue: 0)
        #expect(abs(mid.red - mid.green) < 0.001)
        #expect(abs(mid.green - mid.blue) < 0.001)
        #expect(mid.red > 0.2)
    }

    @Test func builtInContrastPullsMids() {
        let contrast = BuiltInLook.contrast.map(red: 0.5, green: 0.5, blue: 0.5)
        #expect(abs(contrast.0 - 0.5) < 0.001)
        let low = BuiltInLook.contrast.map(red: 0.2, green: 0.2, blue: 0.2)
        #expect(low.0 < 0.2)
        let high = BuiltInLook.contrast.map(red: 0.8, green: 0.8, blue: 0.8)
        #expect(high.0 > 0.8)
    }

    @Test func customLUTIndexKeepsOnlyCubesSortedCaseInsensitively() {
        let stored = CustomLUTIndex.stored(fromFileNames: [
            "b.cube", "A.cube", "notes.txt", "C.CUBE", "sub/dir",
        ])
        #expect(stored.map(\.fileName) == ["A.cube", "b.cube", "C.CUBE"])
        #expect(stored[0].displayName == "A")
        #expect(CustomLUTIndex.displayName(fileName: "Bleach.CUBE") == "Bleach")
        #expect(CustomLUTIndex.displayName(fileName: "weird") == "weird")
    }

    @Test func customLUTIndexRejectsPathComponents() {
        #expect(CustomLUTIndex.isSafeFileName("Look.cube"))
        #expect(!CustomLUTIndex.isSafeFileName("../escape.cube"))
        #expect(!CustomLUTIndex.isSafeFileName("sub/Look.cube"))
        #expect(!CustomLUTIndex.isSafeFileName("Look:cube"))
        #expect(!CustomLUTIndex.isSafeFileName(""))
    }
}

// MARK: - OpenZCine CubeLUT tests (Apache 2.0)

/// Parser and interpolation tests from OpenZCine (Apache 2.0), merged with OpenPocketCine's.
@Test func parsesValidTwoByTwoCube() throws {
    let text = """
        # a comment
        TITLE "demo"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """

    let lut = try CubeLUT.parse(text)

    #expect(lut.size == 2)
    #expect(lut.rgb.count == 2 * 2 * 2 * 3)
    #expect(Array(lut.rgb.prefix(3)) == [0, 0, 0])
    #expect(Array(lut.rgb.suffix(3)) == [1, 1, 1])
}

@Test func skipsDomainAndMetadataLines() throws {
    let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0.0 0.0 0.0
        0.5 0.5 0.5
        0.0 0.0 0.0
        0.0 0.0 0.0
        0.0 0.0 0.0
        0.0 0.0 0.0
        0.0 0.0 0.0
        1.0 1.0 1.0
        """

    let lut = try CubeLUT.parse(text)

    #expect(lut.size == 2)
    #expect(lut.rgb.count == 24)
    #expect(Array(lut.rgb[3..<6]) == [0.5, 0.5, 0.5])
}

@Test func rejectsNonDefaultInputDomain() {
    // A .cube authored for a non-0–1 domain would get the wrong mapping from the renderer, so the
    // parser rejects it rather than apply the wrong colours.
    let text = """
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 2.0 2.0 2.0
        0.0 0.0 0.0
        1.0 1.0 1.0
        """
    #expect(throws: CubeLUTParseError.unsupportedDomain) {
        try CubeLUT.parse(text)
    }
}

@Test func throwsWhenSizeDeclarationMissing() {
    #expect(throws: CubeLUTParseError.missingSize) {
        try CubeLUT.parse("0 0 0\n1 1 1\n")
    }
}

@Test func throwsWhenSampleCountDoesNotMatchSize() {
    let text = """
        LUT_3D_SIZE 2
        0 0 0
        1 1 1
        """

    #expect(throws: CubeLUTParseError.self) {
        try CubeLUT.parse(text)
    }
}

@Test func rejectsDegenerateCubeSizeBelowTwo() {
    // A size of 1 has no interpolation domain; it must be rejected, not parsed.
    #expect(throws: CubeLUTParseError.unsupportedSize(1)) {
        try CubeLUT.parse("LUT_3D_SIZE 1\n0 0 0\n")
    }
}

@Test func rejectsCubeSizeAboveSupportedMaximum() {
    // 66 is past Resolve's 65³ standard and the parser's allocation cap.
    #expect(throws: CubeLUTParseError.unsupportedSize(66)) {
        try CubeLUT.parse("LUT_3D_SIZE 66\n0 0 0\n")
    }
}

@Test func rejectsAbsurdlyLargeDeclaredSizeWithoutAllocating() {
    // A corrupt/hostile file must be rejected on the size line, before the data block is
    // accumulated; otherwise size³ samples (here 3 billion) would exhaust memory.
    #expect(throws: CubeLUTParseError.unsupportedSize(1000)) {
        try CubeLUT.parse("LUT_3D_SIZE 1000\n0 0 0\n")
    }
}

@Test func parsesCubeAtMaximumSupportedSize() throws {
    // 65 is Resolve's standard high-resolution size and must parse.
    let lut = try CubeLUT.parse(zeroCubeText(size: 65))

    #expect(lut.size == 65)
    #expect(lut.rgb.count == 65 * 65 * 65 * 3)
}

@Test func resamplesResolveSizedCubeOntoTheEvenLattice() {
    // OpenZCine's renderer policy (65³ → 33³) through the shared trilinear resample.
    let source = identityCube(size: 65)
    let prepared = source.resampled(to: 33)

    #expect(prepared.size == 33)
    #expect(prepared.rgb.count == 33 * 33 * 33 * 3)
    // 65³ → 33³ hits every other source lattice point exactly (k/32 = 2k/64).
    #expect(Array(prepared.rgb.prefix(3)) == [0, 0, 0])
    #expect(Array(prepared.rgb.suffix(3)) == [1, 1, 1])
    let mid = 16 + 16 * 33 + 16 * 33 * 33
    #expect(abs(prepared.rgb[mid * 3] - 0.5) < 0.0001)
    #expect(identityCube(size: 33).resampled(to: 33).size == 33)
}

@Test func resampledCubeKeepsSourceLatticeValues() {
    var rgb = [Float](repeating: 0, count: 65 * 65 * 65 * 3)
    // A non-identity black that must survive the even-lattice 65³ → 33³ reduction.
    rgb[0] = 0.2
    rgb[1] = 0.3
    rgb[2] = 0.4
    let prepared = CubeLUT(size: 65, rgb: rgb).resampled(to: 33)
    #expect(Array(prepared.rgb.prefix(3)) == [0.2, 0.3, 0.4])
}

/// Identity RGB cube: each lattice point maps to its own normalized coordinate.
private func identityCube(size: Int) -> CubeLUT {
    var rgb = [Float]()
    rgb.reserveCapacity(size * size * size * 3)
    let denominator = Float(size - 1)
    for b in 0..<size {
        for g in 0..<size {
            for r in 0..<size {
                rgb.append(Float(r) / denominator)
                rgb.append(Float(g) / denominator)
                rgb.append(Float(b) / denominator)
            }
        }
    }
    return CubeLUT(size: size, rgb: rgb)
}

/// Builds a syntactically valid `.cube` of `size` filled with zeroed triplets.
private func zeroCubeText(size: Int) -> String {
    var lines = ["LUT_3D_SIZE \(size)"]
    lines.reserveCapacity(size * size * size + 1)
    for _ in 0..<(size * size * size) {
        lines.append("0 0 0")
    }
    return lines.joined(separator: "\n")
}

/// Most Windows LUT tools author CRLF cubes. After the "\n" split every line keeps a trailing
/// "\r", and neither `Int("2\r")` nor `Float("0\r")` parses, so a perfectly valid file was
/// rejected as having no LUT_3D_SIZE at all (OpenZCine #295). The parser must treat "\r" as line junk.
@Test func parsesACRLFAuthoredCubeWithMetadata() throws {
    let text =
        "# a comment\r\n"
        + "TITLE \"demo\"\r\n"
        + "LUT_3D_SIZE 2\r\n"
        + "DOMAIN_MIN 0.0 0.0 0.0\r\n"
        + "DOMAIN_MAX 1.0 1.0 1.0\r\n"
        + "0 0 0\r\n1 0 0\r\n0 1 0\r\n1 1 0\r\n"
        + "0 0 1\r\n1 0 1\r\n0 1 1\r\n1 1 1\r\n"

    let lut = try CubeLUT.parse(text)

    #expect(lut.size == 2)
    #expect(lut.rgb.count == 2 * 2 * 2 * 3)
    #expect(Array(lut.rgb.suffix(3)) == [1, 1, 1])
}
