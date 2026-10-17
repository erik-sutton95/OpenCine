import Foundation
import Testing

@testable import OpenCineCameraControls

/// The pack flow's value rules every app shares: whose cookies carry the session, how a failed
/// page is worded, and what a fetched file is.
@Suite struct MonitorLutPackDownloadTests {
    private let copy = MonitorLutPackCopy(
        intro: "intro", introDetail: "detail", continueLabel: "Continue", hopReady: "hop ready",
        hopUnavailable: "hop unavailable", downloading: "Downloading", success: { "\($0) added" },
        successDetail: "find them", unexpectedSite: "unexpected", noFile: "no file",
        pageFailed: "page failed", httpFailure: { "HTTP \($0)" },
        webPageInsteadOfArchive: "web page",
        notAnArchive: "not an archive")

    private var source: MonitorLutPackSource {
        MonitorLutPackSource(
            pageUrl: "https://maker.example/download", archiveFileName: "pack.zip",
            isAllowedDownload: { $0.hasPrefix("https://maker.example/") },
            cookieOrigins: ["https://www.maker.example", "https://maker.example"], copy: copy)
    }

    #if canImport(Darwin)
        private func cookie(_ domain: String, _ name: String) throws -> HTTPCookie {
            try #require(
                HTTPCookie(properties: [
                    .domain: domain, .path: "/", .name: name, .value: "1",
                ]))
        }

        @Test func cookiesComeFromTheDownloadHostElseTheFirstOriginWithASession() throws {
            let store = try cookie(".storage.example", "signed")
            let maker = try cookie("maker.example", "session")
            let jar = [store, maker]
            #expect(
                lutPackCookies(source: source, url: "https://bucket.storage.example/pack.zip") {
                    lutPackCookies(in: jar, for: $0)
                } == [store])
            // The storage host has no session of its own: the maker's origin carries it.
            #expect(
                lutPackCookies(source: source, url: "https://cdn.other.example/pack.zip") {
                    lutPackCookies(in: jar, for: $0)
                } == [maker])
            #expect(
                lutPackCookies(source: source, url: "https://cdn.other.example/x") { _ in [] }
                    .isEmpty)
        }

    #endif

    @Test func aFailedPageReadsTheNetworkVerdictAndNeverInventsOne() {
        let available = MonitorLutPackReadiness(network: .available, message: "")
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(copy.pageLoadFailure(timedOut, readiness: available) == "page failed")
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(copy.pageLoadFailure(offline, readiness: available) == copy.offline)
        let onCamera = MonitorLutPackReadiness(
            network: .onCameraAccessPoint, message: "on the camera")
        #expect(copy.pageLoadFailure(timedOut, readiness: onCamera) == "on the camera")
        #expect(MonitorLutPackNetwork.noInternet.blocksDownload)
        #expect(!MonitorLutPackNetwork.policyUnavailable.blocksDownload)
    }

    @Test func aFetchedFileIsTheArchiveOrTheSourcesWordsForWhatItIs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, _ bytes: Data) throws -> URL {
            let url = root.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }
        let zip = try file("a.zip", Data([0x50, 0x4B, 0x03, 0x04, 1, 2]))
        #expect(lutPackArchiveCheck(zip, copy: copy) == .success(zip))
        let page = try file("b.zip", Data("  <!doctype html><html>terms".utf8))
        #expect(lutPackArchiveCheck(page, copy: copy) == .failure(.init(message: "web page")))
        let other = try file("c.zip", Data("plain bytes".utf8))
        #expect(
            lutPackArchiveCheck(other, copy: copy) == .failure(.init(message: "not an archive")))
        let empty = try file("d.zip", Data())
        #expect(lutPackArchiveCheck(empty, copy: copy) == .failure(.init(message: "no file")))
    }
}
