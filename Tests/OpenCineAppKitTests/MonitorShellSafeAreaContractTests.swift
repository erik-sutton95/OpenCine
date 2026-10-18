#if os(iOS)
import MonitorPresentation
import MonitorUI
import OpenCineCore
import OpenCineCoreTestSupport
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineAppKit

/// SIMULATED hosted defaults use the same physical-window input as a live app.
/// Explicit host callbacks, including intentional zero insets, retain precedence.
@MainActor
final class MonitorShellSafeAreaContractTests: XCTestCase {
    func testDefaultPagesUsePhysicalWindowInsetsWhenTheHostIgnoresSafeArea() async throws {
        let physical = EdgeInsets(top: 59, leading: 7, bottom: 34, trailing: 3)
        let sample = try await pageInsets(windowInsets: physical)
        XCTAssertEqual(sample, physical)
    }

    func testExplicitHostInsetsTakePrecedenceOverPhysicalWindowFallback() async throws {
        let physical = EdgeInsets(top: 59, leading: 7, bottom: 34, trailing: 3)
        let supplied = EdgeInsets(top: 11, leading: 19, bottom: 23, trailing: 31)
        let sample = try await pageInsets(windowInsets: physical, explicit: supplied)
        XCTAssertEqual(sample, supplied)
    }

    func testExplicitZeroInsetsRemainAnIntentionalHostValue() async throws {
        let sample = try await pageInsets(windowInsets: EdgeInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
            explicit: EdgeInsets())
        XCTAssertEqual(sample, EdgeInsets())
    }

    /// A2-08: the default pages mirror the landscape cutout exactly like the cover page.
    /// iOS reports the island lane on both short edges in landscape; the clean short edge
    /// zeroes so the surface hugs that bezel while clearing the island on the side it sits.
    func testDefaultPagesMirrorTheLandscapeCutoutLikeTheCoverPage() async throws {
        let physical = EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
        let sample = try await pageInsets(windowInsets: physical, size: CGSize(width: 852, height: 393))
        XCTAssertEqual(sample, EdgeInsets(top: 0, leading: 59, bottom: 21, trailing: 0))
    }

    private func pageInsets(
        windowInsets: EdgeInsets, explicit: EdgeInsets? = nil, size: CGSize = CGSize(width: 393, height: 852)
    ) async throws -> EdgeInsets {
        let store = SavedCamerasStore(document: Defaults([:]).at("contract.cameras"))
        let model = ShellModel(cameras: CamerasModel(integrations: [], store: store))
        let probe = ShellSafeAreaProbe()
        let actions = ShellActions(diagnostics: {}, reportProblem: {})
        let windowGeometry = MonitorWindowGeometry(size: size, safeArea: windowInsets)
        let shell: AnyView
        if let explicit {
            shell = AnyView(AppShell(model: model, brand: ShellBrand(name: "SIMULATED"), actions: actions,
                safeArea: { _ in explicit },
                prePage: { insets in ShellSafeAreaSample(insets: insets, probe: probe) },
                monitor: { _ in EmptyView() }, page: { _ in EmptyView() }))
        } else {
            shell = AnyView(AppShell(model: model, brand: ShellBrand(name: "SIMULATED"), actions: actions,
                prePage: { insets in ShellSafeAreaSample(insets: insets, probe: probe) },
                monitor: { _ in EmptyView() }, page: { _ in EmptyView() }))
        }
        let host = UIHostingController(rootView: shell.environment(\.monitorWindowGeometry, windowGeometry))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<200 {
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            if let sample = probe.sample { return sample }
            await Task.yield()
        }
        return try XCTUnwrap(probe.sample, "The actual shared page must publish its received safe area")
    }
}

@MainActor
private final class ShellSafeAreaProbe {
    var sample: EdgeInsets?
}

private struct ShellSafeAreaSample: View {
    let insets: EdgeInsets
    let probe: ShellSafeAreaProbe
    var body: some View {
        Color.clear.onAppear { probe.sample = insets }
            .onChange(of: insets) { _, value in probe.sample = value }
    }
}
#endif
