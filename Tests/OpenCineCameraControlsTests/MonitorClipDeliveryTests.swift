#if os(iOS)
import AVFoundation
import CoreImage
import OpenCineAppKit
import OpenCineApple
import OpenCineCameraVocabulary
import OpenCineMedia
import XCTest

@testable import OpenCineCameraControls

/// The shared clip delivery's export over SIMULATED cached originals (ported from the two log
/// camera apps' adapter and log export tests, A2-61).
@MainActor final class MonitorClipDeliveryTests: XCTestCase {
    private var folder: URL!
    private var store: MonitorDeliveryExportStore!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-clip-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = MonitorDeliveryExportStore(root: folder.appendingPathComponent("store", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func library(cached: [String: URL], shotColor: ColorMode? = nil) -> MonitorClipLibrary {
        .init(
            isCurrent: { true }, connected: { false }, cameraName: { "SIMULATED" },
            isDownloaded: { cached[$0.path] != nil }, download: { _ in },
            downloadProgress: { _ in nil }, localURL: { cached[$0.path] },
            shotColor: { _ in shotColor }, rememberShotColor: { _, _ in })
    }

    private let copy = MonitorClipDeliveryCopy(
        convertHelp: "SIMULATED", convertUnavailableHelp: "SIMULATED", notLog: { "\($0) is not log." })

    private func export(
        _ file: MediaFile, configuration: MonitorClipDelivery.Configuration, library: MonitorClipLibrary
    ) async throws -> URL? {
        try await MonitorClipDelivery.export(
            file, configuration: configuration, library: library,
            look: .init(label: "SIMULATED look", exposureStops: 0, cube: { _ in nil }),
            store: store, admission: .init { true }, progress: { _ in })
    }

    /// ZIB-469: a still travels as its original, so the popup must know it is one.
    func testSelectionTellsStillsFromClips() {
        let still = MonitorClipDelivery.selectionFile(MediaFile(path: "DCIM/DJI_001/DJI_0001.JPG", thumbPath: "", sizeBytes: 4))
        let clip = MonitorClipDelivery.selectionFile(MediaFile(path: "DCIM/DJI_001/DJI_0002.MP4", thumbPath: "", sizeBytes: 4))
        XCTAssertEqual(still.isStill, true)
        XCTAssertEqual(clip.isStill, false)
        XCTAssertEqual(still.filename, "DJI_0001.JPG")
    }
    func testOriginalCopyKeepsBytesAndSidecarAndNeverOverwritesAnotherExport() async throws {
        let source = folder.appendingPathComponent("original.MOV")
        let original = Data([0, 1, 2, 3, 0xff, 0x80])
        try original.write(to: source)
        let file = MediaFile(path: "DCIM/100/SIMULATED_20261004120000_0001_D.MOV", thumbPath: "", sizeBytes: 6)
        var configuration = MonitorClipDelivery.defaultConfiguration()
        configuration.bakeLUT = false
        let library = library(cached: [file.path: source])
        let exportedFirst = try await export(file, configuration: configuration, library: library)
        let exportedSecond = try await export(file, configuration: configuration, library: library)
        let first = try XCTUnwrap(exportedFirst), second = try XCTUnwrap(exportedSecond)
        XCTAssertEqual(first.lastPathComponent, file.filename)
        XCTAssertNotEqual(first, second, "Each export owns its directory")
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertTrue(first.path.hasPrefix(store.exportsDirectory.path))
        let sidecar = first.deletingPathExtension().appendingPathExtension("meta.json")
        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        XCTAssertEqual(decoded?["filename"] as? String, file.filename)
        XCTAssertEqual(decoded?["cameraName"] as? String, "SIMULATED")
        XCTAssertEqual(decoded?["sizeBytes"] as? Int, 6)
        XCTAssertNil(decoded?["lutName"])
        store.release(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testM4VOriginalCopiesToAnMP4WithoutSidecarWhenMetadataIsOff() async throws {
        let source = folder.appendingPathComponent("original.m4v")
        let bytes = Data([0x66, 0x74, 0x79, 0x70, 0, 1, 2])
        try bytes.write(to: source)
        let file = MediaFile(path: "DCIM/100/SIMULATED_0002.m4v", thumbPath: "")
        var configuration = MonitorClipDelivery.defaultConfiguration()
        configuration.bakeLUT = false
        configuration.includeMetadata = false
        configuration.exportFormat = .mp4
        let exported = try await export(file, configuration: configuration, library: library(cached: [file.path: source]))
        let url = try XCTUnwrap(exported)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: url.deletingPathExtension().appendingPathExtension("meta.json").path))
    }

    func testAnUncachedClipAndAMissingLookAreNamedFailures() async throws {
        let file = MediaFile(path: "DCIM/100/SIMULATED_0003.MOV", thumbPath: "")
        var configuration = MonitorClipDelivery.defaultConfiguration()
        configuration.bakeLUT = false
        do {
            _ = try await export(file, configuration: configuration, library: library(cached: [:]))
            XCTFail("An uncached clip must not export")
        } catch {
            XCTAssertEqual(error.localizedDescription, "SIMULATED_0003.MOV isn't fully cached yet.")
        }
        let source = folder.appendingPathComponent("look.MOV")
        try Data([1]).write(to: source)
        configuration.bakeLUT = true
        do {
            _ = try await export(file, configuration: configuration, library: library(cached: [file.path: source]))
            XCTFail("Bake LUT without a look must not export")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Turn on a LUT before baking one into the file.")
        }
        // A refused export leaves nothing behind; the store makes its exports folder only for
        // an export it starts.
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: store.exportsDirectory.path)) ?? [], [])
    }

    func testConvertLogSkipsAClipThatIsNotLog() async throws {
        let source = folder.appendingPathComponent("standard.MOV")
        try Data([1, 2]).write(to: source)
        let file = MediaFile(path: "DCIM/100/SIMULATED_0004.MOV", thumbPath: "")
        var configuration = MonitorClipDelivery.defaultConfiguration()
        configuration.convertLog = true
        let library = library(cached: [file.path: source], shotColor: .normal)
        let exported = try await export(file, configuration: configuration, library: library)
        XCTAssertNil(exported)
        let delivery = MonitorClipDelivery.delivery(
            configuration: configuration, library: library,
            look: { .init(label: nil, exposureStops: 0, cube: { _ in nil }) }, copy: copy, admission: .init { true })
        XCTAssertEqual(delivery.noPrepared([file]), "SIMULATED_0004.MOV is not log.")
    }

    func testLogContextPreservesEncodedRec709TaggedSamples() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_709))
        let value: Float = 0.3994
        let pixels: [Float] = [value, value, value, 1]
        let image = CIImage(
            bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
            size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: space)
        for transform in LogColorTransform.allCases {
            let cube = transform.cube().colorCube
            let filter = try XCTUnwrap(
                CIFilter(
                    name: "CIColorCube",
                    parameters: [
                        kCIInputImageKey: image, "inputCubeDimension": cube.size,
                        "inputCubeData": cube.rgbaComponents.withUnsafeBytes { Data($0) },
                    ]))
            var output = [Float](repeating: 0, count: 4)
            let result = try XCTUnwrap(filter.outputImage)
            output.withUnsafeMutableBytes {
                MonitorMediaExporter.colorContext(preservingEncodedValues: true).render(
                    result, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: image.extent, format: .RGBAf,
                    colorSpace: space)
            }
            let expected = transform.apply(r: Double(value), g: Double(value), b: Double(value))
            XCTAssertEqual(Double(output[0]), expected.r, accuracy: 0.002)
            XCTAssertEqual(Double(output[1]), expected.g, accuracy: 0.002)
            XCTAssertEqual(Double(output[2]), expected.b, accuracy: 0.002)
        }
    }

    func testConvertLogChangesEncodedPixelsAndEmbeddedGammaInBothDirections() async throws {
        for transform in LogColorTransform.allCases {
            let source = folder.appendingPathComponent("\(transform.rawValue).MOV")
            try await writeClip(to: source, gamma: transform.source.label)
            let before = try await readPixel(at: source)
            let file = MediaFile(path: "DCIM/100/\(transform.rawValue).MOV", thumbPath: "")
            var configuration = MonitorClipDelivery.defaultConfiguration()
            configuration.convertLog = true
            configuration.logTransform = transform
            configuration.includeMetadata = false
            let exported = try await export(
                file, configuration: configuration, library: library(cached: [file.path: source]))
            let url = try XCTUnwrap(exported)
            XCTAssertEqual(url.lastPathComponent, "\(transform.rawValue).\(transform.filenameToken).mov")
            let after = try await readPixel(at: url)
            let expected = transform.apply(r: before[0], g: before[1], b: before[2])
            // YUV conversion and lossy video quantization allow a few code values.
            XCTAssertEqual(after[0], expected.r, accuracy: 0.015)
            XCTAssertEqual(after[1], expected.g, accuracy: 0.015)
            XCTAssertEqual(after[2], expected.b, accuracy: 0.015)
            let metadata = try await AVURLAsset(url: url).load(.metadata)
            let gamma = metadata.filter { ($0.key as? String) == ClipColorProfile.gammaKey }
            XCTAssertEqual(gamma.count, 1)
            XCTAssertEqual(gamma.first?.stringValue, transform.destination.label)
            XCTAssertTrue(metadata.contains { $0.stringValue == "Synthetic log fixture" })
        }
    }

    private func writeClip(to url: URL, gamma: String) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let profile = AVMutableMetadataItem()
        profile.keySpace = .quickTimeMetadata
        profile.key = ClipColorProfile.gammaKey as NSString
        profile.value = gamma as NSString
        profile.dataType = kCMMetadataBaseDataType_UTF8 as String
        let title = AVMutableMetadataItem()
        title.identifier = .quickTimeMetadataTitle
        title.value = "Synthetic log fixture" as NSString
        writer.metadata = [profile, title]
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer),
            kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<64 {
            for x in 0..<64 {
                let offset = y * stride + x * 4
                base[offset] = 102
                base[offset + 1] = 102
                base[offset + 2] = 102
                base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        for frame in 0..<3 {
            for _ in 0..<200 where !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
    }

    private func readPixel(at url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        defer { reader.cancelReading() }
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let center =
            (CVPixelBufferGetHeight(buffer) / 2) * CVPixelBufferGetBytesPerRow(buffer)
            + (CVPixelBufferGetWidth(buffer) / 2) * 4
        return [Double(data[center + 2]) / 255, Double(data[center + 1]) / 255, Double(data[center]) / 255]
    }
}
#endif
