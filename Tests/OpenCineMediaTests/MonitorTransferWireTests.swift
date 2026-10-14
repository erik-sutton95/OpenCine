import Testing

@testable import OpenCineMedia

/// Kotlin twin: MonitorTransferWireTest. Named curves are distinct from raw camera identifiers.
@Suite struct MonitorTransferWireTests {
    @Test func namedCurvesRoundTripWithoutDependingOnEnumOrder() {
        let vectors: [(MonitorTransfer, String)] = [
            (.rec709, "rec709"), (.hdr, "hdr"), (.dlog, "dlog"), (.dlog2, "dlog2"),
            (.dlogm, "dlogm"), (.ilog, "ilog"), (.srgb, "srgb"), (.nlog, "nlog"),
            (.log3G10, "log3G10"),
        ]
        #expect(vectors.count == MonitorTransfer.allCases.count)
        for (value, name) in vectors {
            #expect(MonitorTransferWire.tag(value) == name)
            #expect(MonitorTransferWire.transfer(name) == value)
        }
    }

    @Test func missingAndUnclassifiedNamesStayUnknown() {
        let names: [String?] = [nil, "", "65536", "unknown", "HDR", "PQ", "Dolby Vision", " ilog "]
        for name in names {
            #expect(MonitorTransferWire.transfer(name) == nil)
        }
    }
}
