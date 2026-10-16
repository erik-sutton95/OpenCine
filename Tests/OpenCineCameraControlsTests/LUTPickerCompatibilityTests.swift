#if os(iOS)
import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineHostedAccessibility
import OpenCineMedia
import SwiftUI
import UIKit
import XCTest

/// SIMULATED native compatibility and rendering through the public picker/preview interfaces.
@MainActor
final class LUTPickerCompatibilityTests: XCTestCase {
    func testTheOriginalGenericPickerStillRendersItsSuppliedFooter() async throws {
        let name = "lut-picker-compatibility." + UUID().uuidString
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer {
            storage.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let preferences = LUTPreferences(storage: storage, namespace: name)
        let looks = MonitorLUTLooks(
            official: OfficialLUTs(catalog: { _ in [.officialAuto] }, cube: { _ in nil }),
            preferences: preferences, customLUTs: CustomLUTStore(root: root, preferences: preferences))
        let assist = MonitorAssistState(looks: looks, storage: storage,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        let picker: LUTPickerView<MonitorDefaultLivePalette, Text> = LUTPickerView(
            assist: assist,
            context: .init(colorMode: nil, isPhoto: false, inPlayback: false,
                family: .fallback, cameraName: nil, isWatching: false),
            copy: .init(officialTab: "Camera", officialLockedCaption: "", officialCaption: "",
                customEmptyHint: "Import a look"), palette: MonitorDefaultLivePalette.self) {
                Text("Legacy supplied footer")
            }
        let hosted = try Hosted(picker)
        defer { hosted.close() }
        for _ in 0..<100 {
            hosted.host.view.layoutIfNeeded()
            if hosted.labels.contains("Legacy supplied footer") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(hosted.labels.contains("Legacy supplied footer"), hosted.labels.joined(separator: ", "))
    }

    /// Actual published pin call forms, including nil availability/callback and exact function arity.
    func testPublishedComparisonCallFormsCompileWithoutAmbiguousDefaults() throws {
        let name = "legacy-comparison-call-forms." + UUID().uuidString
        let storage = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { storage.removePersistentDomain(forName: name) }
        let assist = MonitorAssistState(looks: IndependentLooks(), storage: storage,
            keys: .init(assist: "assist", cleanPins: "pins", playback: "playback"), cleanPinCases: [])
        let haptics = OperatorHaptics(isEnabled: { false })
        _ = MonitorOperatorLookComparison(assist: assist, haptics: haptics)
        _ = MonitorOperatorLookComparison(assist: assist, haptics: haptics, exposureAvailable: true)
        _ = MonitorOperatorLookComparison(assist: assist, haptics: haptics, exposureAvailable: false)
        _ = MonitorOperatorLookComparison(assist: assist, haptics: haptics, exposureAvailable: nil)
        _ = MonitorOperatorLookComparison(assist: assist, haptics: haptics, onArm: {})
        _ = MonitorOperatorLookComparison(assist: assist, haptics: haptics, onArm: nil)
        let oldInitializer: (MonitorAssistState<IndependentLooks>, OperatorHaptics, Bool?, (() -> Void)?)
            -> MonitorOperatorLookComparison<IndependentLooks> = MonitorOperatorLookComparison.init
        _ = oldInitializer(assist, haptics, nil, {})
    }

    private final class IndependentLooks: MonitorLookProvider {
        var selection = 7
        var cube: CubeLUT? { nil }
        var transfer: MonitorTransfer { .rec709 }
        var referenceClipByte: Int { 255 }
        func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
        var appliesLUTExposure: Bool { false }
    }

    @MainActor
    private final class Hosted {
        let host: UIHostingController<AnyView>
        let window: UIWindow
        let previous: UIWindow?
        init(_ view: some View) throws {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            previous = scene?.keyWindow
            host = UIHostingController(rootView: AnyView(view))
            host.safeAreaRegions = []
            // SwiftPM's native test host has no application scene. Its real window still
            // hosts and renders SwiftUI; app-hosted tests use their foreground scene.
            window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0, y: 0, width: 420, height: 900)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
        }
        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        var labels: [String] {
            HostedAccessibility.elements(in: window).filter(\.isAccessibilityElement).compactMap(\.accessibilityLabel)
        }
    }

    private func greenPixels(_ image: UIImage) throws -> Int {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: cgImage.width,
                height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return stride(from: 0, to: bytes.count, by: 4).filter { index in
            let red = Int(bytes[index])
            let green = Int(bytes[index + 1])
            let blue = Int(bytes[index + 2])
            return green > 90 && green * 10 > red * 13 && green * 10 > blue * 13
        }.count
    }
}
#endif
