#if os(iOS)
import MonitorUI
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

@testable import OpenCineCameraControls

/// SIMULATED operator changes through the actual shared picker, store and render payloads.
@MainActor
final class LUTRefreshRegressionTests: XCTestCase {
    private static let identity =
        "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
    private let context = LUTPickerContext(colorMode: .normal, isPhoto: false,
        inPlayback: false, family: .fallback, cameraName: nil, isWatching: false)
    private let copy = LUTPickerCopy(officialTab: "Camera", officialLockedCaption: "",
        officialCaption: "", customEmptyHint: "Import a look")

    // Catches a wheel that only centers on appear, or writes its old resting row back after
    // an external selection. The same mounted picker must move in both directions.
    func testMountedPickerCentersExternalSelectionWithoutRestoringItsOldLook() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let assist = fixture.assist
        assist.selectLUT(.creativeMono)
        let picker = LUTPickerView(assist: assist, embedded: true, context: context,
            copy: copy, palette: MonitorDefaultLivePalette.self) { EmptyView() }
        let hosted = Hosted(picker)
        defer { hosted.close() }
        guard try await assertCentered(.creativeMono, row: 0, in: hosted) else { return }

        for (selection, row): (LUTSelection, Int) in [(.creativeCool, 3), (.creativeMono, 0), (.creativeWarm, 2)] {
            assist.selectLUT(selection)
            guard try await assertCentered(selection, row: row, in: hosted) else { return }
            XCTAssertEqual(assist.lutSelection, selection)
            XCTAssertEqual(fixture.preferences.lutSelection, selection)
        }
    }

    // Catches stale assist/inspector payloads even when the store itself reads fresh bytes.
    func testSameNamePickerImportRefreshesPreparedAndInspectorCubesWithoutChangingIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let assist = fixture.assist
        assist.selectLUT(.creativeWarm)
        let source = fixture.root.appendingPathComponent("source/Operator Look.cube")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(Self.identity.utf8).write(to: source)
        let importCube = try XCTUnwrap(assist.lutPickerLibraries(context: context, copy: copy)
            .first { $0.layout == .files }?.importCube)
        try importCube(source)
        let first = assist.effects.lutRGBA
        let firstInspector = assist.inspectorLUT(transfer: .rec709).rgba
        XCTAssertEqual(first.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(4)) }, [0, 0, 0, 1])
        XCTAssertEqual(firstInspector, first)

        let replacement = Self.identity.replacingOccurrences(of: "0 0 0\n", with: "1 0 0\n")
        try Data(replacement.utf8).write(to: source)
        try importCube(source)
        XCTAssertEqual(assist.lutSelection, .customFile)
        XCTAssertEqual(fixture.preferences.selectedCustomFileName, "Operator Look.cube")
        XCTAssertEqual(assist.looks.customLUTs.list().map(\.fileName), ["Operator Look.cube"])
        let refreshed = assist.effects.lutRGBA
        XCTAssertNotEqual(refreshed, first)
        XCTAssertEqual(refreshed.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(4)) }, [1, 0, 0, 1])
        XCTAssertEqual(assist.inspectorLUT(transfer: .rec709).rgba, refreshed)

        try Data("not a cube".utf8).write(to: source)
        XCTAssertThrowsError(try importCube(source))
        XCTAssertEqual(assist.effects.lutRGBA, refreshed)
        XCTAssertEqual(assist.inspectorLUT(transfer: .rec709).rgba, refreshed)
        XCTAssertEqual(fixture.preferences.selectedCustomFileName, "Operator Look.cube")
        XCTAssertEqual(try Data(contentsOf: assist.looks.customLUTs.root
            .appendingPathComponent("Operator Look.cube")), Data(replacement.utf8))
    }

    private func assertCentered(_ selection: LUTSelection, row: Int, in hosted: Hosted) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        var delta: CGFloat?
        repeat {
            hosted.host.view.layoutIfNeeded()
            if let scroll = hosted.verticalScroll {
                // The supplied Creative catalog has four equal-height rows: Mono, Contrast,
                // Warm, Cool. Measure the actual scroll geometry, including its content inset;
                // SwiftUI does not vend the wheel's masked rows as accessibility elements.
                let rowCenter = (CGFloat(row) + 0.5) * scroll.contentSize.height / 4
                delta = rowCenter - scroll.bounds.midY
                if abs(delta!) < 2 { return true }
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        var scrolls: [String] = []
        func describe(_ view: UIView) {
            if let scroll = view as? UIScrollView {
                scrolls.append("\(type(of: scroll)): bounds=\(scroll.bounds), content=\(scroll.contentSize)")
            }
            view.subviews.forEach(describe)
        }
        describe(hosted.host.view)
        XCTFail("The mounted LUT wheel did not center \(selection.title); vertical offset: \(String(describing: delta)); scrolls: \(scrolls)")
        return false
    }

    @MainActor private final class Fixture {
        let domain = "LUTRefreshRegressionTests." + UUID().uuidString
        let root: URL
        let storage: UserDefaults
        let preferences: LUTPreferences
        let assist: MonitorAssistState<MonitorLUTLooks>
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
            storage = try XCTUnwrap(UserDefaults(suiteName: domain))
            preferences = LUTPreferences(storage: storage, namespace: "App")
            let looks = MonitorLUTLooks(official: OfficialLUTs(catalog: { _ in [.officialAuto] },
                cube: { _ in nil }), preferences: preferences,
                customLUTs: CustomLUTStore(root: root.appendingPathComponent("library"), preferences: preferences))
            assist = MonitorAssistState(looks: looks, storage: storage,
                keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        }
        func close() {
            storage.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let previous: UIWindow?
        init(_ view: some View) {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            previous = scene?.keyWindow
            host = UIHostingController(rootView: AnyView(view))
            host.safeAreaRegions = []
            window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0, y: 0, width: 420, height: 900)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }
        var verticalScroll: UIScrollView? {
            func find(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    return scroll
                }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(host.view)
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
#endif
