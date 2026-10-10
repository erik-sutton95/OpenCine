import OpenCineAppKit
import Testing

@Suite struct MonitorDeliveryFileValuesTests {
    @Test func originalNameAndContainerCaseRemainExact() {
        var configuration = MonitorDeliveryExportConfiguration(logTransform: 1, exportFormat: 1)
        #expect(MonitorDeliveryFileNaming.filename(original: "SIMULATED.MP4", configuration: configuration, formatExtension: "mov") == "SIMULATED.mov")
        configuration.bakeLUT = false
        #expect(MonitorDeliveryFileNaming.filename(original: "SIMULATED.MP4", configuration: configuration, formatExtension: "mov") == "SIMULATED.MP4")
    }
    @Test func convertedTagDoesNotRenameAnUnconvertedOriginal() {
        var configuration = MonitorDeliveryExportConfiguration(logTransform: 1, exportFormat: 1)
        #expect(MonitorDeliveryFileNaming.filename(original: "SIMULATED.MP4", configuration: configuration, formatExtension: "mov", transformToken: "log") == "SIMULATED.mov")
        configuration.convertLog = true
        #expect(MonitorDeliveryFileNaming.filename(original: "SIMULATED.MP4", configuration: configuration, formatExtension: "mov", transformToken: "log") == "SIMULATED.log.mov")
    }
    @Test func missingMetadataNeverInvokesAnInventedByteFormatter() {
        let unknown = MonitorDeliveryMetadataFacts(filename: "SIMULATED", captureDate: nil, sizeBytes: nil)
        var formatted: [UInt64] = []
        let text = MonitorDeliveryMetadataSummary.text(files: [unknown]) { formatted.append($0); return "unexpected" }
        #expect(unknown.captureDate == nil && unknown.sizeBytes == nil && formatted.isEmpty)
        #expect(text == "SIMULATED · unknown date · unknown size")
    }
    @Test func metadataOrderAndKnownValuesRemainExact() {
        let text = MonitorDeliveryMetadataSummary.text(files: [
            .init(filename: "SIMULATED-A", captureDate: "2026-10-07", sizeBytes: 123),
            .init(filename: "SIMULATED-B", captureDate: nil, sizeBytes: nil)
        ]) { "\($0) bytes" }
        #expect(text == "SIMULATED-A · 2026-10-07 · 123 bytes\nSIMULATED-B · unknown date · unknown size")
    }
    @Test func conversionWinsOverLutMetadataAndDisabledMetadataIncludesNothing() {
        var configuration = MonitorDeliveryExportConfiguration(logTransform: 1, exportFormat: 1)
        let baked = MonitorDeliveryMetadataSelection(configuration)
        #expect(baked.included && baked.bakedLook && baked.bakedExposure && !baked.convertedCurve)
        configuration.convertLog = true
        let converted = MonitorDeliveryMetadataSelection(configuration)
        #expect(converted.included && !converted.bakedLook && !converted.bakedExposure && converted.convertedCurve)
        configuration.includeMetadata = false
        let absent = MonitorDeliveryMetadataSelection(configuration)
        #expect(!absent.included && !absent.bakedLook && !absent.bakedExposure && !absent.convertedCurve)
    }
}
