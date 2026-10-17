import Foundation
import OpenCineNikon
import Testing

struct NikonScalarPropertyDescriptorTests {
    // SIMULATED existing UINT8 property, not a proposed movie-tone wire identity.
    private let property = PTPPropertyCode.movieFocusMode.rawValue
    private var extended: [UInt8] {
        ByteCoding.uint32LE(property) + [2, 0, 1, 0, 2, 2, 3, 0, 0, 2, 255]
    }

    @Test func preservesReportedMetadataAndUnknownEnum() throws {
        let observed = try #require(
            NikonScalarPropertyDescriptor.parse(
                Data(extended), property: property, valueByteCount: 1))
        #expect(observed.writable)
        #expect(observed.defaultValue == [0])
        #expect(observed.currentValue == [2])
        #expect(observed.form == .enumeration([[0], [2], [255]]))
        var readOnly = extended
        readOnly[6] = 0
        #expect(
            NikonScalarPropertyDescriptor.parse(
                Data(readOnly), property: property, valueByteCount: 1)?
                .writable == false)
    }

    @Test func standardAndExtendedWidthsDoNotAcceptAnAlias() {
        let standard =
            ByteCoding.uint16LE(UInt16(truncatingIfNeeded: property))
            + Array(extended.dropFirst(4))
        #expect(
            NikonScalarPropertyDescriptor.parse(
                Data(standard), property: property, valueByteCount: 1)
                != nil)
        #expect(
            NikonScalarPropertyDescriptor.parse(
                Data(standard), property: property | 0x10000, valueByteCount: 1) == nil)
        #expect(
            NikonScalarPropertyDescriptor.parse(
                Data(extended), property: property + 1, valueByteCount: 1)
                == nil)
    }

    @Test func rejectsMalformedTruncatedAndTrailingDatasets() {
        for count in 0..<extended.count {
            #expect(
                NikonScalarPropertyDescriptor.parse(
                    Data(extended.prefix(count)), property: property, valueByteCount: 1) == nil)
        }
        for index in [4, 6, 9] {
            var malformed = extended
            malformed[index] = 7
            #expect(
                NikonScalarPropertyDescriptor.parse(
                    Data(malformed), property: property, valueByteCount: 1) == nil)
        }
        #expect(
            NikonScalarPropertyDescriptor.parse(
                Data(extended + [0]), property: property, valueByteCount: 1) == nil)
    }
}
