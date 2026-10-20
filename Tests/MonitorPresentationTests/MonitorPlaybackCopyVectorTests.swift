import Foundation
import MonitorPresentation
import Testing

/// The Swift half of `Fixtures/playback-copy.tsv`. Compose keeps the twin `MonitorPlaybackCopy` in
/// `Android/monitor-ui` and reads the same rows (`MonitorPlaybackCopyVectorTest`), so the playback
/// screen reads the same on both platforms.
@Suite struct MonitorPlaybackCopyVectorTests {
    static let rows: [[String]] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MonitorPresentationTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let path = root.appendingPathComponent("Fixtures/playback-copy.tsv").path
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }()

    /// Every constant, by the fixture key.
    static let constants: [String: String] = [
        "backToMedia": MonitorPlaybackCopy.backToMedia,
        "favorite": MonitorPlaybackCopy.favorite,
        "clipInformation": MonitorPlaybackCopy.clipInformation,
        "share": MonitorPlaybackCopy.share,
        "shareTitle": MonitorPlaybackCopy.shareTitle,
        "delete": MonitorPlaybackCopy.delete,
        "clipInformationTitle": MonitorPlaybackCopy.clipInformationTitle,
        "closeClipInformation": MonitorPlaybackCopy.closeClipInformation,
        "deleteConfirmationTitle": MonitorPlaybackCopy.deleteConfirmationTitle,
        "deleteConfirm": MonitorPlaybackCopy.deleteConfirm,
        "deleteCancel": MonitorPlaybackCopy.deleteCancel,
        "deleteCancelDescription": MonitorPlaybackCopy.deleteCancelDescription,
        "deleteConfirmDescription": MonitorPlaybackCopy.deleteConfirmDescription,
        "backFifteen": MonitorPlaybackCopy.backFifteen,
        "forwardFifteen": MonitorPlaybackCopy.forwardFifteen,
        "play": MonitorPlaybackCopy.play,
        "pause": MonitorPlaybackCopy.pause,
        "restart": MonitorPlaybackCopy.restart,
        "previousClip": MonitorPlaybackCopy.previousClip,
        "nextClip": MonitorPlaybackCopy.nextClip,
        "conformPreview": MonitorPlaybackCopy.conformPreview,
        "closeConformPreview": MonitorPlaybackCopy.closeConformPreview,
        "mute": MonitorPlaybackCopy.mute,
        "unmute": MonitorPlaybackCopy.unmute,
        "loop": MonitorPlaybackCopy.loop,
        "on": MonitorPlaybackCopy.on,
        "off": MonitorPlaybackCopy.off,
        "hideControls": MonitorPlaybackCopy.hideControls,
        "hideControlsHint": MonitorPlaybackCopy.hideControlsHint,
        "showControls": MonitorPlaybackCopy.showControls,
        "position": MonitorPlaybackCopy.position,
        "conformTitle": MonitorPlaybackCopy.conformTitle,
        "realTime": MonitorPlaybackCopy.realTime,
        "showRating": MonitorPlaybackCopy.showRating,
        "hideRating": MonitorPlaybackCopy.hideRating,
    ]

    static func rows(_ kind: String) -> [[String]] { rows.filter { $0.first == kind } }

    @Test func everyConstantReadsTheSharedText() {
        let fixture = Self.rows("text")
        #expect(
            Set(fixture.map { $0[1] }) == Set(Self.constants.keys),
            "fixture missing or a constant unshared")
        #expect(fixture.count == Self.constants.count, "a key appears twice")
        for row in fixture { #expect(Self.constants[row[1]] == row[2], "\(row)") }
    }

    @Test func derivedLabelsReadTheSharedText() throws {
        let transport = Self.rows("transport")
        #expect(transport.count == 4)
        for row in transport {
            #expect(
                MonitorPlaybackCopy.transport(reachedEnd: row[1] == "1", playing: row[2] == "1")
                    == row[3], "\(row)")
        }
        let mute = Self.rows("mute")
        let toggle = Self.rows("toggle")
        let rating = Self.rows("rating")
        #expect(mute.count == 2 && toggle.count == 2 && rating.count == 2)
        for row in mute {
            #expect(MonitorPlaybackCopy.muteToggle(muted: row[1] == "1") == row[2], "\(row)")
        }
        for row in toggle {
            #expect(MonitorPlaybackCopy.toggleValue(row[1] == "1") == row[2], "\(row)")
        }
        for row in rating {
            #expect(MonitorPlaybackCopy.rating(expanded: row[1] == "1") == row[2], "\(row)")
        }
        let position = Self.rows("position")
        #expect(position.count >= 5)
        for row in position {
            let seconds = try #require(
                row[1] == "nan" ? Double.nan : row[1] == "inf" ? Double.infinity : Double(row[1]))
            #expect(MonitorPlaybackCopy.positionValue(seconds: seconds) == row[2], "\(row)")
        }
        let rate = Self.rows("rate")
        #expect(rate.count >= 2)
        for row in rate {
            #expect(MonitorPlaybackCopy.rate(try #require(Int(row[1]))) == row[2], "\(row)")
        }
        let conform = Self.rows("conform")
        #expect(conform.count >= 2)
        for row in conform {
            #expect(
                MonitorPlaybackCopy.conformSubtitle(captureRate: try #require(Double(row[1])))
                    == row[2], "\(row)")
        }
    }
}
