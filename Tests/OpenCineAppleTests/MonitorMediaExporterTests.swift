#if canImport(AVFoundation) && canImport(CoreImage) && !os(watchOS)
    import Foundation
    import OpenCineApple
    import Testing

    @Suite struct MonitorMediaExporterTests {
        private struct Metadata: Codable, Sendable {
            let filename: String
            let exportedAt: Date
            let optionalValue: String?
        }

        private final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Double] = []
            func append(_ value: Double) {
                lock.withLock { values.append(value) }
            }
            func snapshot() -> [Double] { lock.withLock { values } }
        }

        @Test func passthroughPreservesSourceAndWritesTheExistingSidecarShape() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            // This path copies bytes without asking AVFoundation to decode them.
            let original = Data([0, 1, 127, 255])
            let source = folder.appendingPathComponent("source.m4v")
            let output = folder.appendingPathComponent("output.mp4")
            try original.write(to: source)
            try Data("stale output".utf8).write(to: output)
            let progress = Progress()
            let result = try await MonitorMediaExporter.export(
                sourceURL: source, outputURL: output, format: .mp4,
                metadata: Metadata(
                    filename: "source.m4v", exportedAt: Date(timeIntervalSince1970: 123),
                    optionalValue: nil), progress: { progress.append($0) })
            #expect(result.videoURL == output)
            #expect(try Data(contentsOf: source) == original)
            #expect(try Data(contentsOf: output) == original)
            let sidecar = try #require(result.metadataURL)
            #expect(sidecar.lastPathComponent == "output.meta.json")
            let sidecarBytes = try Data(contentsOf: sidecar)
            #expect(
                String(decoding: sidecarBytes, as: UTF8.self) == """
                    {
                      "exportedAt" : "1970-01-01T00:02:03Z",
                      "filename" : "source.m4v"
                    }
                    """)
            #expect(progress.snapshot() == [0.9, 1])
        }

        @Test func absentMetadataDoesNotCreateASidecar() async throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("source.mov")
            let output = folder.appendingPathComponent("output.mov")
            try Data([12, 34]).write(to: source)
            let result = try await MonitorMediaExporter.export(
                sourceURL: source, outputURL: output, format: .mov,
                metadata: Optional<Metadata>.none, progress: { _ in })
            #expect(result.metadataURL == nil)
            #expect(
                !FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("output.meta.json").path))
            #expect(try Data(contentsOf: source) == Data(contentsOf: output))
        }
    }
#endif
