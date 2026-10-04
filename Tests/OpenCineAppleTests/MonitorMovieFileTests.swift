#if canImport(AVFoundation) && !os(watchOS)
    import AVFoundation
    import Foundation
    import OpenCineApple
    import Testing
    import os

    @Suite struct MonitorMovieFileTests {
        private let header = Data([0, 0, 0, 8, 109, 111, 111, 118])

        @Test func completeAndUnknownPayloadsRemainDistinct() throws {
            try withFile(
                header + Data([0, 0, 0, 16, 109, 100, 97, 116]) + Data(repeating: 7, count: 8)
            ) { url in
                #expect(MonitorMovieFile.movieHasFinishedHeader(at: url))
                #expect(!MonitorMovieFile.mediaDataExtendsPastEndOfFile(at: url))
                #expect(MonitorMovieFile.mdatAvailableFraction(at: url) == nil)
            }
            try withFile(Data([0, 0, 0, 8, 102, 114, 101, 101])) { url in
                #expect(!MonitorMovieFile.movieHasFinishedHeader(at: url))
                #expect(!MonitorMovieFile.mediaDataExtendsPastEndOfFile(at: url))
                #expect(MonitorMovieFile.mdatAvailableFraction(at: url) == nil)
            }
        }

        @Test func ordinaryAndExtendedHeadersScaleOnlyTheMissingPayload() throws {
            let ordinary = Data([0, 0, 0, 40, 109, 100, 97, 116])
            let extended = Data([0, 0, 0, 1, 109, 100, 97, 116, 0, 0, 0, 0, 0, 0, 0, 48])
            for atom in [ordinary, extended] {
                try withFile(header + atom + Data(repeating: 7, count: 8)) { url in
                    #expect(MonitorMovieFile.movieHasFinishedHeader(at: url))
                    #expect(MonitorMovieFile.mediaDataExtendsPastEndOfFile(at: url))
                    #expect(MonitorMovieFile.mdatAvailableFraction(at: url) == 0.25)
                    let duration = CMTime(seconds: 10, preferredTimescale: 25_000)
                    #expect(
                        MonitorMovieFile.scaledProgressDuration(for: url, headerDuration: duration)
                            .seconds == 2.5)
                    #expect(
                        !MonitorMovieFile.scaledProgressDuration(for: url, headerDuration: .invalid)
                            .isValid)
                }
            }
        }

        @Test func timecodeAdmissionReportsTypedInformationWithoutTouchingOutput() async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("partial.mov")
            let destination = directory.appendingPathComponent("export.mov")
            try (header + Data([0, 0, 0, 40, 109, 100, 97, 116])).write(to: source)
            let messages = OSAllocatedUnfairLock(initialState: [String]())
            await MonitorMovieTimecode.copySourceTimecodeTrack(
                from: source, to: destination, as: .mov
            ) { diagnostic in
                switch diagnostic.level {
                case .information:
                    messages.withLock { $0.append(diagnostic.message) }
                case .error:
                    Issue.record("partial source admission must report information")
                }
            }
            #expect(
                messages.withLock { $0 } == ["timecode embed skipped: source mdat is truncated"])
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }

        private func withFile(_ bytes: Data, check: (URL) throws -> Void) throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            try check(url)
        }
    }
#endif
