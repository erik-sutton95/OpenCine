import Foundation
import Testing

import OpenCineStreaming

@Suite struct StreamServicePresetTests {
    @Test func tableHoldsTheFourServices() {
        #expect(StreamServicePreset.all.map(\.id) == ["twitch", "youtube", "facebook", "instagram"])
    }

    @Test func everyFixedServerParsesAsRTMPS() throws {
        for preset in StreamServicePreset.all {
            if let url = preset.serverURL {
                #expect(!preset.requiresServerEntry)
                _ = try StreamDestination(serverURL: url, streamKey: "k")
            } else {
                #expect(preset.requiresServerEntry)
            }
        }
    }

    @Test func instagramAsksForServerAndIsVertical() throws {
        let p = try #require(StreamServicePreset.all.first { $0.id == "instagram" })
        #expect(p.serverURL == nil && p.requiresServerEntry && p.aspect == .portrait9x16)
    }

    @Test func customAsksForServer() {
        let p = StreamServicePreset.custom
        #expect(p.serverURL == nil && p.requiresServerEntry && p.aspect == .landscape16x9 && p.maxVideoBitrateBps == nil)
        #expect(!StreamServicePreset.all.contains(p))
    }

    @Test func onlyCustomAcceptsPlainRTMP() {
        #expect(StreamServicePreset.custom.allowsPlainRTMP)
        #expect(StreamServicePreset.all.allSatisfy { !$0.allowsPlainRTMP })
    }

    @Test func everyPresetHasAKeyHint() {
        for p in StreamServicePreset.all + [.custom] {
            #expect(!p.keyHint.isEmpty, "\(p.id)")
            #expect(!p.displayName.isEmpty, "\(p.id)")
        }
    }

    @Test func idsAreUnique() {
        let ids = (StreamServicePreset.all + [.custom]).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
