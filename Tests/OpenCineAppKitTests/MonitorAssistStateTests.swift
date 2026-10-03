import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineMedia
import Testing

@MainActor
@Suite struct MonitorAssistStateTests {
    private func storage() throws -> (UserDefaults, String) {
        let domain = "opencine-assist-state-tests." + UUID().uuidString
        return (try #require(UserDefaults(suiteName: domain)), domain)
    }
    private var keys: MonitorAssistPreferenceKeys {
        .init(assist: "assist", cleanPins: "pins", playback: "playback")
    }
    private var allowed: [MonitorAssistSelection] {
        MonitorAssistTool.allCases.filter { $0 != .evMeter }.map(MonitorAssistSelection.init)
    }

    @Test func pinsPlaybackAndCoveredScopesHaveOneIndependentOwner() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = MonitorAssistState(looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        state.toggle(.waveform)
        state.toggle(.peaking)
        state.clean = true
        #expect(state.waveform && !state.effects.waveform && state.effects.peaking)
        state.toggleCleanViewPin(.waveform)
        #expect(state.effects.waveform && state.waveform)
        state.togglePlayback(.zebra)
        #expect(state.playbackEffects.zebra && !state.zebra)
        state.liveCovered = true
        #expect(!state.effects.waveform && state.effects.peaking)
        state.configureTool = .waveform
        #expect(state.effects.waveform)
        state.inspectorSceneActive = false
        #expect(!state.effects.waveform)
        state.toggleCleanViewPin(.evMeter)
        #expect(!state.cleanViewPinnedTools.contains(.evMeter))
        let reloaded = MonitorAssistState(looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        #expect(reloaded.waveform && reloaded.peaking && reloaded.cleanViewPinnedTools.contains(.waveform))
        #expect(reloaded.playbackVisibleTools == [.zebra] && !reloaded.zebra)
        let other = MonitorAssistState(looks: StateTestLooks(), storage: defaults,
            keys: .init(assist: "other", cleanPins: "otherPins", playback: "otherPlayback"), cleanPinCases: allowed)
        #expect(!other.waveform && other.playbackVisibleTools.isEmpty)
    }

    @Test func legacySelectionsDoNotExpandTheCurrentCatalog() throws {
        guard #available(macOS 14, *) else { return }
        #expect(MonitorAssistTool.allCases.count == 18)
        #expect(MonitorAssistSelection.allCases.map(\.rawValue).prefix(18) == MonitorAssistTool.allCases.map(\.rawValue)[...])
        #expect(MonitorAssistSelection(rawValue: "PLAY") == .instantReview)
        #expect(MonitorAssistSelection(rawValue: "MAG") == .magnification)
        #expect(MonitorAssistSelection(rawValue: "UNKNOWN") == nil)
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = MonitorAssistState(looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        state.toggle(.instantReview)
        state.toggle(.magnification)
        let restored = MonitorAssistState(looks: StateTestLooks(), storage: defaults, keys: keys, cleanPinCases: allowed)
        #expect(restored.instantReview && !restored.isOn(.magnification))
        let snapshot = try JSONDecoder().decode(MonitorAssistSnapshot.self, from: #require(state.encodedSnapshot()))
        #expect(snapshot.tools == ["LUT", "PLAY"])
    }

    @Test func sharedCubePreparationKeepsInspectorAndMainEnablementIndependent() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let looks = StateTestLooks()
        let state = MonitorAssistState(looks: looks, storage: defaults, keys: keys, cleanPinCases: allowed)
        let nominal = try #require(state.exportCube(bakeExposure: false))
        state.lutEnabled = false
        state.refreshLUTCube()
        #expect(state.effects.lutDimension == 0 && state.exportCube(bakeExposure: false) == nil)
        state.waveform = true
        state.mirrorVertical = true
        let preview = state.inspectorImageOptions(tool: .peaking, transfer: .hdr, clipByte: 227)
        #expect(preview.peaking && !preview.waveform && !preview.zebra && !preview.inspectorSample)
        #expect(preview.transfer == .hdr && preview.resolvedClipByte == 227)
        #expect(state.waveform && !state.peaking && state.effects.lutDimension == 0)
        let mirror = state.inspectorImageOptions(tool: .mirror, transfer: .rec709, clipByte: 255)
        #expect(mirror.mirror && mirror.mirrorVertical && !state.mirror)
        let inspectorEffects = state.inspectorImageEffects(tool: .lut, transfer: .rec709, clipByte: 255)
        #expect(inspectorEffects.lutDimension == 2 && !state.lutEnabled)
        let first = state.inspectorLUT(transfer: .rec709)
        #expect(first.dimension == 2 && !first.rgba.isEmpty && !state.lutEnabled)
        looks.selection = 1
        let second = state.inspectorLUT(transfer: .rec709)
        #expect(first.rgba != second.rgba)
        state.armLastLUT()
        state.nudgeLUTExposure(-0.5)
        #expect(state.lutExposureStops == -0.5 && state.effects.lutDimension == 2)
        #expect(state.exportCube(bakeExposure: false) != nominal)
        #expect(state.exportCube(bakeExposure: true) != state.exportCube(bakeExposure: false))
    }

    @Test func sourceCalibrationAndBakeCurveAreExplicitMediaInputs() throws {
        guard #available(macOS 14, *) else { return }
        let (defaults, domain) = try storage()
        defer { defaults.removePersistentDomain(forName: domain) }
        let looks = StateTestLooks()
        looks.transfer = .dlogm; looks.bakeTransfer = .dlog; looks.referenceClipByte = 223
        let state = MonitorAssistState(looks: looks, storage: defaults, keys: keys, cleanPinCases: allowed)
        #expect(state.effects.transfer == .dlogm && state.effects.resolvedClipByte == 223)
        state.nudgeLUTExposure(-1)
        let expected = try #require(looks.cube).preparedForExport(bakeExposure: true, stops: -1, transfer: .dlog)
        #expect(state.exportCube(bakeExposure: true) == expected)
    }
}

@MainActor private final class StateTestLooks: MonitorLookProvider {
    var selection = 0
    var transfer = MonitorTransfer.rec709
    var bakeTransfer: MonitorTransfer?
    var referenceClipByte = 255
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { bakeTransfer ?? transfer }
    var cube: CubeLUT? {
        CubeLUT(size: 2, rgb: (0..<8).flatMap { index -> [Float] in
            let r = Float(index & 1), g = Float((index >> 1) & 1), b = Float((index >> 2) & 1)
            return selection == 0 ? [r, g, b] : [b, r, g]
        })
    }
}
