import Testing

@testable import OpenCineMedia

/// The import trust boundary moved from OpenZCine's Android facade (A4-27).
@Suite struct CubeLUTImportTests {
    private let identity = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"

    @Test func acceptsAStrictCube() throws {
        let cube = try #require(CubeLUT.validatedImport(Array(identity.utf8)))
        #expect(cube.size == 2)
    }

    @Test func acceptsFloatExportOvershoot() throws {
        // Official RED size-33 packs write lattice points as 1.000001.
        let text = identity.replacingOccurrences(of: "1 1 1\n", with: "1.000001 1.000001 1.000001\n")
        #expect(CubeLUT.validatedImport(Array("TITLE \"look\"\n\(text)".utf8)) != nil)
    }

    @Test(arguments: [
        "not a cube",
        "LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n",
        "LUT_3D_SIZE 2\n1.2 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n",
        "LUT_3D_SIZE 2\n-nan 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n",
        "LUT_3D_SIZE 2\n0 0 0\n",
    ])
    func rejectsWhatMustNotBeStored(text: String) {
        #expect(CubeLUT.validatedImport(Array(text.utf8)) == nil)
    }

    @Test func rejectsInvalidUTF8AndOversizedSources() {
        #expect(CubeLUT.validatedImport(Array(identity.utf8) + [0xFF]) == nil)
        #expect(CubeLUT.validatedImport(Array(repeating: 120, count: CubeLUT.maximumImportBytes + 1)) == nil)
    }
}
