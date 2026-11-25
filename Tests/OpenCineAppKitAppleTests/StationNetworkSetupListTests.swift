#if os(iOS)
import OpenCineAppKit
import OpenCineCore
import OpenCineHostedAccessibility
import OpenCineHostedTestSupport
import SwiftUI
import Testing
import UIKit
@testable import OpenCineAppKitApple

/// The network list's layout: where Other network sits and what an empty list says, as the page's
/// decisions and, for the pinned row outside the scrolling list, in a hosted window (a scroll
/// view's content is reachable only in an application scene). SIMULATED networks; nothing joins
/// or scans.
@MainActor @Suite struct StationNetworkSetupListTests {
    private let brand = StationNetworkBrand(appName: "App", cameraFamily: "Cam", cameraNetworkPrefix: "cam")

    private func services(current: String? = nil) -> StationNetworkServices {
        StationNetworkServices(
            savedNetworks: { [] }, currentSSID: { current }, hotspotActive: { false },
            acceptsJoin: { _, _ in true })
    }

    /// Hosts `view` in a window of `size` and waits for the elements named by `identifiers`,
    /// returning their frames in window coordinates.
    private func frames(
        of view: StationNetworkSetupView, size: CGSize, identifiers: Set<String>
    ) async -> (frames: [String: CGRect], labels: [String]) {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        var found: [String: CGRect] = [:]
        _ = await HostedCondition.wait {
            controller.view.layoutIfNeeded()
            found = [:]
            for element in HostedAccessibility.elements(in: window) {
                guard let id = HostedAccessibility.identifier(element), identifiers.contains(id) else { continue }
                found[id] = window.convert(element.accessibilityFrame, from: nil)
            }
            return found.count == identifiers.count
        }
        return (found, HostedAccessibility.leaves(in: window).compactMap(\.accessibilityLabel))
    }

    private func layout(
        _ host: HostDevice, cameraScans: Bool = false, current: String? = nil, saved: [String] = [],
        nearby: [String] = [], scanning: Bool = false, denied: Bool = false
    ) -> StationNetworkSetupView.ListLayout {
        StationNetworkSetupView.ListLayout(
            host: host, cameraScans: cameraScans,
            rows: StationNetworkRows(current: current, saved: saved, nearby: nearby) { _ in false },
            computerScanning: scanning, locationDenied: denied)
    }

    @Test func anEmptyComputerListLeadsWithOtherNetworkAndSaysWhy() {
        let empty = layout(.mac)
        #expect(empty.oneColumn, "A computer with no camera scan lays its list out in one column")
        #expect(empty.otherNetworkLeads)
        #expect(empty.emptyNote == "Type the name of the Wi-Fi the cameras should join.")
        #expect(
            layout(.mac, denied: true).emptyNote
                == "Allow Location for this module in System Settings to show the Mac’s Wi-Fi.")
        // Still looking, or any network to choose: Other network stays pinned under the list.
        #expect(!layout(.mac, scanning: true).otherNetworkLeads)
        for listed in [layout(.mac, current: "Studio"), layout(.mac, saved: ["Office"]), layout(.mac, nearby: ["Hall"])] {
            #expect(listed.oneColumn)
            #expect(!listed.otherNetworkLeads)
            #expect(listed.emptyNote == nil)
        }
        // A camera scanning for the computer keeps the two-column page and its Nearby column.
        #expect(!layout(.mac, cameraScans: true).oneColumn)
        #expect(!layout(.mac, cameraScans: true).otherNetworkLeads)
    }

    @Test func aPhoneListKeepsItsLayout() {
        for phone in [layout(.iPhone), layout(.iPhone, cameraScans: true), layout(.iPhone, current: "Studio")] {
            #expect(!phone.oneColumn)
            #expect(!phone.otherNetworkLeads)
            #expect(phone.emptyNote == nil)
        }
    }

    @Test(arguments: [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402)])
    func aPhoneListPinsOtherNetworkUnderTheList(size: CGSize) async throws {
        #expect(await HostedAccessibility.awaitRuntime())
        let view = StationNetworkSetupView(
            host: .iPhone, context: .multiview, brand: brand, services: services(current: "Studio"),
            scan: nil, save: { _ in true }, close: {}, path: [.networks], complete: {})
        let other = "multiview.setup.otherNetwork"
        let (frames, labels) = await frames(of: view, size: size, identifiers: [other])
        let row = try #require(frames[other], "Shown: \(labels)")
        #expect(row.maxY > size.height * 0.8, "Other network stays pinned at the bottom: \(row) in \(size)")
        if size.height > size.width {
            #expect(row.width >= size.width - 2 * 18 - 1, "Portrait: full width under the list: \(row)")
        } else {
            #expect(row.minX > size.width / 2 - 1, "Landscape: under the Nearby column: \(row)")
        }
    }

    @Test func aComputerAskedForItsNetworkListOpensItOnce() {
        // Add setup's Wi-Fi on a computer asks for the list, which is already its first page:
        // pushing it again made Back show the same page.
        #expect(StationNetworkSetupView.startPath([.networks], root: StationNetworkSetupView.root(.mac)) == [])
        #expect(
            StationNetworkSetupView.startPath([.networks, .password("Studio")], root: .networks)
                == [.password("Studio")])
        #expect(StationNetworkSetupView.startPath([.networks], root: StationNetworkSetupView.root(.iPhone)) == [.networks])
        #expect(StationNetworkSetupView.startPath([.password("Studio")], root: .networks) == [.password("Studio")])
    }
}
#endif
