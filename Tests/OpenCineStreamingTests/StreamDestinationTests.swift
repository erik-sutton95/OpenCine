import Foundation
import Testing

@testable import OpenCineStreaming

@Suite struct StreamDestinationTests {
    @Test func parsesServicePath() throws {
        let d = try StreamDestination(serverURL: "rtmps://live.example.com:443/rtmp/", streamKey: "abc")
        #expect(d.host == "live.example.com")
        #expect(d.port == 443)
        #expect(d.app == "rtmp")
        #expect(d.tcURL == "rtmps://live.example.com:443/rtmp")
    }

    @Test func keepsSeveralAppSegments() throws {
        let d = try StreamDestination(serverURL: "rtmps://a.example.com/stage/live", streamKey: "k")
        #expect(d.app == "stage/live")
        #expect(d.tcURL == "rtmps://a.example.com:443/stage/live")
    }

    @Test func defaultPortIs443() throws {
        #expect(try StreamDestination(serverURL: "rtmps://a.example.com/live2", streamKey: "k").port == 443)
    }

    @Test func plainRTMPIsRefused() {
        #expect(throws: StreamDestinationError.notRTMPS) {
            try StreamDestination(serverURL: "rtmp://a.example.com/live2", streamKey: "k")
        }
    }

    @Test(arguments: ["rtmps://", "rtmps:///app", "not a url", "rtmps://host:99999/app", "rtmps://host"])
    func malformedServerIsRefused(url: String) {
        #expect(throws: StreamDestinationError.invalidServerURL) {
            try StreamDestination(serverURL: url, streamKey: "k")
        }
    }

    @Test func destinationTrimsPastedWhitespace() throws {
        let d = try StreamDestination(serverURL: " rtmps://a.example.com/app\n", streamKey: "  key-1?s=2&t=3 \n")
        #expect(d.streamKey == "key-1?s=2&t=3")
        #expect(d.app == "app")
    }

    @Test func emptyKeyIsRefused() {
        #expect(throws: StreamDestinationError.emptyKey) {
            try StreamDestination(serverURL: "rtmps://a.example.com/app", streamKey: "  \n")
        }
    }

    @Test func keyThatIsAURLIsRefused() {
        #expect(throws: StreamDestinationError.keyLooksLikeURL) {
            try StreamDestination(serverURL: "rtmps://a.example.com/app", streamKey: "rtmps://x/y")
        }
    }

    @Test func keyIsInNoDescription() throws {
        let d = try StreamDestination(serverURL: "rtmps://a.example.com/app", streamKey: "SECRETKEY")
        for text in [
            "\(d)", String(reflecting: d),
            String(describing: Mirror(reflecting: d).children.map { "\($0)" }),
        ] {
            #expect(!text.contains("SECRETKEY"))
        }
    }

    @Test func testSeamAllowsPlainRTMPForTheLocalReceiver() throws {
        let d = try StreamDestination(testOnlyPlainServerURL: "rtmp://127.0.0.1:1935/live", streamKey: "k")
        #expect(d.port == 1935)
        #expect(d.tcURL == "rtmp://127.0.0.1:1935/live")
    }
}
