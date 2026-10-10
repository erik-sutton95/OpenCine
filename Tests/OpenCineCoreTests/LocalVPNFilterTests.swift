import Foundation
import OpenCineCore
import Testing

// Moved from the app cores' LocalVPNFilterTests (OpenPocketCine superset) with the copy unchanged.

@Suite struct LocalVPNFilterTests {
    @Test func liveHintWaitsForStallWithoutPicture() {
        #expect(
            !LocalVPNFilter.shouldHintOnLiveWait(
                vpnActive: true, hadVideo: false, secondsWithoutVideo: 7))
        #expect(
            LocalVPNFilter.shouldHintOnLiveWait(
                vpnActive: true, hadVideo: false, secondsWithoutVideo: 8))
        #expect(
            !LocalVPNFilter.shouldHintOnLiveWait(
                vpnActive: true, hadVideo: true, secondsWithoutVideo: 30))
        #expect(
            !LocalVPNFilter.shouldHintOnLiveWait(
                vpnActive: false, hadVideo: false, secondsWithoutVideo: 30))
    }

    @Test func tunnelInterfaceNames() {
        #expect(LocalVPNFilter.isTunnelInterface("utun2"))
        #expect(LocalVPNFilter.isTunnelInterface("ipsec0"))
        #expect(LocalVPNFilter.isTunnelInterface("ppp0"))
        #expect(LocalVPNFilter.isTunnelInterface("tap0"))
        #expect(!LocalVPNFilter.isTunnelInterface("en0"))
        #expect(!LocalVPNFilter.isTunnelInterface("wlan0"))
        #expect(!LocalVPNFilter.isTunnelInterface("lo0"))
    }

    @Test func operatorCopyDoesNotNameSisterApps() {
        let facing = [
            LocalVPNFilter.wizardBanner,
            LocalVPNFilter.liveHint,
            LocalVPNFilter.joinWifiPhoneStep,
        ]
        for text in facing {
            #expect(!text.localizedCaseInsensitiveContains("OpenZCine"))
            #expect(!text.localizedCaseInsensitiveContains("Nikon"))
            #expect(!text.localizedCaseInsensitiveContains("Mimo"))
            #expect(!text.localizedCaseInsensitiveContains("AdGuard"))
            #expect(!text.localizedCaseInsensitiveContains("Blokada"))
        }
    }
}

#if os(iOS) || os(macOS)
    @Suite struct LocalVPNNoticeTests {
        @Test func notesAnActiveTunnelOncePerInstance() {
            let lines = Lines()
            let active = Lines()
            let notice = LocalVPNNotice(isActive: { active.count > 0 }, note: { lines.append($0) })
            notice.noteIfActive()
            #expect(lines.count == 0)
            active.append("utun0")
            notice.noteIfActive()
            notice.noteIfActive()
            #expect(lines.all == [LocalVPNNotice.message])
        }

        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.withLock { values.append(value) } }
            var all: [String] { lock.withLock { values } }
            var count: Int { all.count }
        }
    }
#endif
